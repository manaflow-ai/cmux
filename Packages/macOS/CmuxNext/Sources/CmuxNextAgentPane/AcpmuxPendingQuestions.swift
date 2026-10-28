public import Foundation
import CmuxNextCompat

/// Live question membership from the daemon, separate from retained permission/nonce history.
/// Only a pending notification or a complete pending snapshot can open an entry. History can
/// retire it or update an already-live reissue, but cannot authorize a historical card.
public nonisolated final class AcpmuxPendingQuestions: Sendable {
    public struct Question: Sendable, Equatable {
        public let connection: Int
        public let sessionId: String
        public let permissionId: String
        public let generation: UUID
        public let decisionNonce: String
        public let personInstance: String
        public let requestDigest: String
        /// Full immutable daemon request, including normalized items/options and original
        /// AskUserQuestion previews. Native reply validation reads this snapshot, never history
        /// or page-supplied request content. This value is not exposed through a page bridge.
        public let requestJSON: String
        public let allowOnce: Set<String>
        public let answerKeys: Set<String>
    }

    private struct Entry {
        var question: Question
        var seq: UInt64
    }

    private struct Session {
        var pending: [String: Entry] = [:]
        var retired: [String: UInt64] = [:]
        var snapshotSeq: UInt64?
        /// Highest daemon sequence observed for this session. It survives lag so an old
        /// in-flight snapshot cannot resurrect a request from before the gap.
        var observedSeq: UInt64?
        var retiredThrough: UInt64?
        var suspended = false
    }

    private struct State {
        var connection: Int?
        var sessions: [String: Session] = [:]
        var requiresSnapshot = false
        /// Epoch increments on a lag. Snapshot replies must be correlated to a request
        /// issued after that epoch; a method name alone cannot distinguish an old reply.
        var recoveryEpoch: UInt64 = 0
        var snapshotRequests: [Int: UInt64] = [:]
    }

    // Keep tombstones until a complete snapshot covers them. At the bound, stop granting new
    // membership until another snapshot; evicting a tombstone must never revive old history.
    static let limit = 256
    /// A keyboard witness refuses a larger request; the existing click path remains available.
    static let maximumRequestBytes = 1_048_576
    private let state = Mutex(State())

    public init() {}

    public func reset(connection: Int?) {
        state.withLock { $0 = State(connection: connection) }
    }

    /// A stale socket closing after its replacement cannot retire the new connection.
    func end(connection: Int) {
        state.withLock { state in
            if state.connection == connection { state = State() }
        }
    }

    public func question(session: String, permission: String, connection: Int) -> Question? {
        state.withLock { state in
            guard state.connection == connection else { return nil }
            return state.sessions[session]?.pending[permission]?.question
        }
    }

    public func questions(connection: Int) -> [Question] {
        state.withLock { state in
            guard state.connection == connection else { return [] }
            return state.sessions.values.flatMap { $0.pending.values.map(\.question) }
        }
    }

    /// Recheck after private renderer redemption and immediately before spending the credit.
    public func isCurrent(_ question: Question) -> Bool {
        state.withLock { state in
            state.connection == question.connection
                && state.sessions[question.sessionId]?.pending[question.permissionId]?.question == question
        }
    }

    /// Subscription metadata from the checked outbound frame, for both free and gesture paths.
    /// Detach/watch-off immediately revoke authority even if the daemon later refuses them.
    func request(method: String?, session: String?, watchEnabled: Bool?, token: Int?, connection: Int) {
        state.withLock { state in
            guard state.connection == connection else { return }
            if method == "_acpmux/detach", let id = Self.identifier(session) {
                Self.suspend([id], in: &state)
            } else if method == "_acpmux/watch", watchEnabled == false {
                Self.suspend(nil, in: &state)
            } else if method == "_acpmux/attach" || method == "_acpmux/watch", let token,
                      state.snapshotRequests.count < Self.limit {
                state.snapshotRequests[token] = state.recoveryEpoch
            }
        }
    }

    /// A request that failed before reaching the daemon cannot redeem a recovery epoch.
    func snapshotRequestCancelled(token: Int, connection: Int) {
        state.withLock { state in
            guard state.connection == connection else { return }
            state.snapshotRequests[token] = nil
        }
    }

    /// Called from the socket's ordered parse, before any of this frame reaches page script.
    func observe(_ object: [String: Any], replyTo method: String?, connection: Int,
                 snapshotRequestToken: Int? = nil) {
        state.withLock { state in
            guard state.connection == connection else { return }
            if object["method"] as? String == "_acpmux/lagged" {
                let ids = (object["params"] as? [String: Any])?["sessionIds"] as? [String]
                Self.suspend(ids?.isEmpty == false ? ids : nil, in: &state)
                return
            }
            if object["method"] as? String == "_acpmux/session_changed",
               let params = object["params"] as? [String: Any],
               let id = Self.identifier((params["session"] as? [String: Any])?["sessionId"] ?? params["sessionId"]) {
                guard state.sessions[id] != nil || state.sessions.count < Self.limit else { return }
                if let seq = Self.sequence(params["seq"]) {
                    guard Self.observeSequence(seq, session: id, in: &state) else { return }
                }
                let kind = params["recordKind"] as? String ?? params["kind"] as? String
                let closed = (params["session"] as? [String: Any])?["status"] as? String == "closed"
                let settlement = kind == "permission_decision" || kind == "permission_resolved" || kind == "permission_auto"
                    || kind == "turn_end" || kind == "turn_result" || kind == "turn_error"
                if kind == "purged" || closed || settlement {
                    // A watcher summary has only pendingPermissions, not permission ids. Retire
                    // every locally live proof and require a complete post-notice read.
                    Self.suspend([id], in: &state)
                    state.sessions[id]?.retiredThrough = max(state.sessions[id]?.retiredThrough ?? 0,
                                                             Self.sequence(params["seq"]) ?? .max)
                    return
                }
            }
            if object["method"] as? String == "_acpmux/permission_pending",
               let params = object["params"] as? [String: Any],
               let session = Self.identifier(params["sessionId"]), let seq = Self.sequence(params["seq"]) {
                Self.pending(params, session: session, seq: seq, connection: connection, in: &state)
                return
            }
            if object["method"] as? String == "_acpmux/event", let record = object["params"] as? [String: Any] {
                Self.record(record, connection: connection, in: &state)
                return
            }
            // Only matched daemon replies are snapshots. Agent/model result objects are never read.
            guard object["method"] == nil else { return }
            let tokenEpoch = snapshotRequestToken.flatMap { state.snapshotRequests.removeValue(forKey: $0) }
            guard let result = object["result"] as? [String: Any] else { return }
            if method == "_acpmux/attach" || method == "_acpmux/watch" {
                // Every opening snapshot must answer a native relay id issued in this epoch.
                guard tokenEpoch == state.recoveryEpoch else { return }
                let snapshots = (result["sessions"] as? [[String: Any]] ?? [])
                    + [result["session"] as? [String: Any]].compactMap { $0 }
                for snapshot in snapshots {
                    if snapshot["pending"] is [[String: Any]] {
                        Self.snapshot(snapshot, fallbackSeq: result["lastSeq"], connection: connection, in: &state)
                    } else {
                        Self.summary(snapshot, in: &state)
                    }
                }
            }
            if ["_acpmux/attach", "_acpmux/watch", "_acpmux/events"].contains(method ?? ""),
               let records = result["events"] as? [[String: Any]] {
                // Replayed requests cannot open entries; later settlements still retire them.
                for record in records { Self.record(record, connection: connection, in: &state) }
            }
        }
    }

    private static func pending(_ params: [String: Any], session id: String, seq: UInt64,
                                connection: Int, in state: inout State, snapshot: Bool = false) {
        guard let permission = identifier(params["permissionId"]) else { return }
        guard state.sessions[id] != nil || state.sessions.count < limit else { return }
        guard Self.observeSequence(seq, session: id, in: &state) else { return }
        var session = state.sessions[id] ?? Session(suspended: state.requiresSnapshot)
        guard snapshot || !session.suspended else { return }
        if let retired = session.retired[permission], seq <= retired { return }
        if let floor = session.retiredThrough, seq <= floor { return }
        if let previous = session.pending[permission], seq < previous.seq { return }
        // The snapshot proves absence at its watermark. A delayed older notification cannot
        // add an absent entry. Repeated identical sightings of a present entry remain stable.
        if !snapshot, let floor = session.snapshotSeq, seq <= floor, session.pending[permission] == nil { return }
        let candidate = makeQuestion(params, session: id, permission: permission, connection: connection)
        if let previous = session.pending[permission] {
            if let candidate, sameRequest(previous.question, candidate) {
                session.pending[permission]?.seq = max(seq, previous.seq)
                state.sessions[id] = session
                return
            }
            if seq == previous.seq {
                retire(permission, seq: seq, session: &session)
                state.sessions[id] = session
                return
            }
        }
        let total = state.sessions.values.reduce(0) { $0 + $1.pending.count }
        if let candidate, session.pending[permission] != nil || total < limit {
            session.pending[permission] = Entry(question: candidate, seq: seq)
        } else {
            retire(permission, seq: seq, session: &session)
        }
        state.sessions[id] = session
    }

    private static func snapshot(_ snapshot: [String: Any], fallbackSeq: Any?, connection: Int, in state: inout State) {
        guard let id = identifier(snapshot["sessionId"]), let seq = sequence(snapshot["lastSeq"] ?? fallbackSeq),
              let prompts = snapshot["pending"] as? [[String: Any]], prompts.count <= limit,
              state.sessions[id] != nil || state.sessions.count < limit else { return }
        var session = state.sessions[id] ?? Session()
        if let observed = session.observedSeq, seq < observed { return }
        if let known = session.snapshotSeq, seq < known { return }
        session.observedSeq = max(session.observedSeq ?? 0, seq)
        let present = Set(prompts.compactMap { identifier($0["permissionId"]) })
        for (permission, entry) in session.pending where entry.seq <= seq && !present.contains(permission) {
            session.pending[permission] = nil
        }
        let repeated = session.snapshotSeq == seq
        session.snapshotSeq = seq
        session.suspended = false
        session.retired = session.retired.filter { $0.value >= seq }
        state.sessions[id] = session
        // A complete snapshot owns this session's membership; other suspended sessions stay shut.
        for prompt in prompts {
            if repeated, let permission = identifier(prompt["permissionId"]), session.pending[permission] == nil { continue }
            pending(prompt, session: id, seq: seq, connection: connection, in: &state, snapshot: true)
        }
    }

    private static func record(_ record: [String: Any], connection: Int, in state: inout State) {
        guard let id = identifier(record["sessionId"]), let seq = sequence(record["seq"]),
              state.sessions[id] != nil || state.sessions.count < limit,
              observeSequence(seq, session: id, in: &state) else { return }
        // Every event direction raises the monotonic floor, but only daemon mux records
        // carry membership changes. Model output never supplies pending request authority.
        guard record["dir"] as? String == "mux", let kind = record["kind"] as? String,
              let message = record["msg"] as? [String: Any] else { return }
        var session = state.sessions[id] ?? Session(suspended: state.requiresSnapshot)
        if kind == "permission_decision", let permission = identifier(message["permissionId"]) {
            if let current = session.pending[permission], seq < current.seq { return }
            retire(permission, seq: seq, session: &session)
        } else if kind == "turn_end" || kind == "turn_result" || kind == "turn_error"
            || (kind == "status" && message["status"] as? String == "closed")
            || (kind == "permission_decision" && message["permissionId"] == nil) {
            session.pending = session.pending.filter { $0.value.seq > seq }
            session.retiredThrough = max(session.retiredThrough ?? 0, seq)
        } else if kind == "permission_reissued" || kind == "permission_request" {
            guard let permission = identifier(message["permissionId"]), session.pending[permission] != nil else { return }
            pending(message, session: id, seq: seq, connection: connection, in: &state)
            return
        } else { return }
        state.sessions[id] = session
    }

    /// No ids are present in a normal watch summary. Zero proves absence only; a positive
    /// count cannot choose which locally retained question is still pending.
    private static func summary(_ summary: [String: Any], in state: inout State) {
        guard let id = identifier(summary["sessionId"]), let seq = sequence(summary["lastSeq"]),
              sequence(summary["pendingPermissions"]) == 0,
              state.sessions[id] != nil || state.sessions.count < limit,
              observeSequence(seq, session: id, in: &state) else { return }
        state.sessions[id]?.pending = [:]
        state.sessions[id]?.snapshotSeq = seq
        state.sessions[id]?.retiredThrough = max(state.sessions[id]?.retiredThrough ?? 0, seq)
    }

    private static func suspend(_ ids: [String]?, in state: inout State) {
        // Invalidate all in-flight reads before clearing entries. Tokens never survive a gap,
        // detach, watch-off, or a watcher settlement; only a later complete read can reopen.
        state.recoveryEpoch &+= 1
        state.snapshotRequests.removeAll()
        if ids == nil { state.requiresSnapshot = true }
        for id in ids ?? Array(state.sessions.keys) {
            guard state.sessions[id] != nil || state.sessions.count < limit else {
                state.requiresSnapshot = true
                continue
            }
            var session = state.sessions[id] ?? Session()
            session.pending = [:]
            session.suspended = true
            state.sessions[id] = session
        }
    }

    private static func observeSequence(_ seq: UInt64, session id: String,
                                         in state: inout State) -> Bool {
        var session = state.sessions[id] ?? Session(suspended: state.requiresSnapshot)
        if let observed = session.observedSeq, seq < observed { return false }
        session.observedSeq = max(session.observedSeq ?? 0, seq)
        state.sessions[id] = session
        return true
    }

    private static func retire(_ permission: String, seq: UInt64, session: inout Session) {
        session.pending[permission] = nil
        if session.retired.count >= limit, session.retired[permission] == nil {
            session.pending = [:]
            session.suspended = true
            return
        }
        session.retired[permission] = max(seq, session.retired[permission] ?? 0)
    }

    private static func makeQuestion(_ params: [String: Any], session: String, permission: String, connection: Int) -> Question? {
        guard let nonce = params["decisionNonce"] as? String, hex(nonce, count: 64),
              let instance = params["personInstance"] as? String, hex(instance, count: 32),
              let request = params["request"] as? [String: Any],
              let keys = AcpmuxPermissionOptions.questionKeys(request), !keys.isEmpty, keys.count <= 128,
              keys.allSatisfy({ $0.utf8.count <= AcpmuxPaneMethods.maximumAnswerBytes }),
              let options = request["options"] as? [[String: Any]], !options.isEmpty, options.count <= limit,
              let requestJSON = AcpmuxSecretKey.canonicalJSON(request), requestJSON.utf8.count <= maximumRequestBytes,
              let digest = AcpmuxSecretKey.canonicalDigest(request) else { return nil }
        let ids = options.compactMap { identifier($0["optionId"]) }
        guard ids.count == options.count, Set(ids).count == ids.count else { return nil }
        let allow = Set(options.compactMap { $0["kind"] as? String == "allow_once" ? $0["optionId"] as? String : nil })
        guard !allow.isEmpty else { return nil }
        return Question(connection: connection, sessionId: session, permissionId: permission, generation: UUID(),
                        decisionNonce: nonce, personInstance: instance, requestDigest: digest, requestJSON: requestJSON,
                        allowOnce: allow, answerKeys: keys)
    }

    private static func sameRequest(_ lhs: Question, _ rhs: Question) -> Bool {
        lhs.requestDigest == rhs.requestDigest && lhs.decisionNonce == rhs.decisionNonce && lhs.personInstance == rhs.personInstance
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256, !text.contains("\u{0}") else { return nil }
        return text
    }

    private static func hex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func sequence(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.uint64Value
    }
}
