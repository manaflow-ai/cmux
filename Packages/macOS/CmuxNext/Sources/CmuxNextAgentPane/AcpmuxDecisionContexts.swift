public import Foundation
import CmuxNextCompat

/// The decision nonce and daemon run of each prompt this pane was shown (acpmux
/// `_acpmux/permission_pending`, cx-0q7o): what a relayed allow's proof covers. The newest one per
/// prompt wins (a prompt the next daemon adopted comes again, with a new nonce and run). Bounded:
/// the oldest prompt goes first.
public nonisolated final class AcpmuxDecisionContexts: Sendable {
    public struct Context: Sendable, Equatable {
        public let nonce: String
        public let instance: String
        /// The prompt's `toolCall.toolCallId` (empty for none): an enrolled Mac's signature covers it.
        public var toolCall = ""
        /// The options the prompt offers once each as a one-time allow (`allow_once`): the only
        /// ones an enrolled Mac may sign (acpmux `mac_approvers::may_allow`).
        public var allowOnce: Set<String> = []
    }

    /// A permission group the page read (`_acpmux/permission_groups`): its revision and its pending
    /// members, each with the option a group's Allow once selects for it (acpmux
    /// `permission_groups::option`, empty when it has none).
    public struct Group: Sendable, Equatable {
        public let revision: UInt64
        public let pending: [String: String]
    }

    static let limit = 256

    private struct State {
        var order: [String] = []
        var byKey: [String: Context] = [:]
        /// The log seq each context came from: an older page replayed later never wins.
        var seqByKey: [String: UInt64] = [:]
        var localInstance: String?
        /// The peer that last refused an allow for want of the person's proof (acpmux
        /// `permission.person_required` with `data.peer`), until the pane takes it.
        var refusedBy: String?
        var groups: [String: Group] = [:]
        var groupOrder: [String] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Reads one inbound frame, as the page gets it.
    func observe(_ object: [String: Any], replyTo method: String?) {
        if method == "_acpmux/permission_respond" || method == "_acpmux/permission_group_respond",
           let error = object["error"] as? [String: Any] {
            let data = error["data"] as? [String: Any]
            if data?["reason"] as? String == "permission.person_required", let peer = data?["peer"] as? String, !peer.isEmpty {
                state.withLock { $0.refusedBy = peer }
            }
            return
        }
        if method == "_acpmux/permission_groups" {
            let groups = (object["result"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
            return groups.forEach(noteGroup)
        }
        if method == AcpmuxPaneMethods.initialize {
            let meta = ((object["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            let instance = meta?["personInstance"] as? String
            state.withLock { $0.localInstance = instance }
            return
        }
        // A prompt the page learns from the event log (a live `_acpmux/event`, or the records of an
        // attach or events page: a chat on another machine whose prompt came before the page
        // attached, cx-oa6ah) carries the same nonce and run in its `permission_request` record.
        if object["method"] as? String == "_acpmux/event", let record = object["params"] as? [String: Any] {
            return observeRecord(record)
        }
        // Only the daemon's own replies are read (an agent's forwarded result could carry a
        // `session` or `events` member of its own).
        let snapshotReply = method == "_acpmux/attach" || method == "_acpmux/watch"
        if let result = object["result"] as? [String: Any], snapshotReply || method == "_acpmux/events" {
            // A session snapshot (`_acpmux/attach` `session`, `_acpmux/watch` `sessions`) lists its
            // open prompts with their nonce and run: after a keyed restart the re-issued prompt
            // may reach a page that reconnected only through it (cx-0w0jj proof). Its seq is the
            // session's `lastSeq`, so a later re-issue still wins.
            let sessions = !snapshotReply ? [] : (result["sessions"] as? [[String: Any]] ?? []) + [result["session"] as? [String: Any]].compactMap { $0 }
            for snapshot in sessions {
                // Without a seq a snapshot could hide a later re-issue: it is not read.
                guard let session = snapshot["sessionId"] as? String, let pending = snapshot["pending"] as? [[String: Any]],
                      let seq = (snapshot["lastSeq"] as? NSNumber)?.uint64Value ?? (result["lastSeq"] as? NSNumber)?.uint64Value
                else { continue }
                for prompt in pending { note(session: session, prompt, seq: seq) }
            }
            if let events = result["events"] as? [[String: Any]] {
                return events.forEach(observeRecord)
            }
        }
        guard object["method"] as? String == "_acpmux/permission_pending",
              let params = object["params"] as? [String: Any],
              let session = params["sessionId"] as? String
        else { return }
        note(session: session, params, seq: (params["seq"] as? NSNumber)?.uint64Value)
    }

    /// One event record: a `permission_request` or `permission_reissued` names its prompt's nonce and run.
    private func observeRecord(_ record: [String: Any]) {
        // Only the daemon's own (`mux`) records name a prompt's nonce and run.
        guard record["dir"] as? String == "mux",
              let kind = record["kind"] as? String, kind == "permission_request" || kind == "permission_reissued",
              let session = record["sessionId"] as? String, let message = record["msg"] as? [String: Any] else { return }
        note(session: session, message, seq: (record["seq"] as? NSNumber)?.uint64Value)
    }

    private func note(session: String, _ params: [String: Any], seq: UInt64?) {
        guard let permission = params["permissionId"] as? String,
              let nonce = params["decisionNonce"] as? String, let instance = params["personInstance"] as? String
        else { return }
        // A context that is not in acpmux's form is dropped: no proof is ever made over it.
        guard Self.isHex(nonce, count: 64), Self.isHex(instance, count: 32),
              !session.contains("\u{0}"), !permission.contains("\u{0}") else { return }
        let key = session + "\u{0}" + permission
        var context = Context(nonce: nonce, instance: instance)
        let request = params["request"] as? [String: Any]
        context.toolCall = (request?["toolCall"] as? [String: Any])?["toolCallId"] as? String ?? ""
        let options = request?["options"] as? [[String: Any]] ?? []
        let ids = options.compactMap { $0["optionId"] as? String }
        context.allowOnce = Set(options.compactMap { option in
            guard option["kind"] as? String == "allow_once", let id = option["optionId"] as? String,
                  ids.count(where: { $0 == id }) == 1 else { return nil }
            return id
        })
        state.withLock { state in
            if let seq, let known = state.seqByKey[key], seq < known { return }
            // An update without a seq is the newest the pane knows: no replayed record replaces it.
            state.seqByKey[key] = seq ?? .max
            guard state.byKey.updateValue(context, forKey: key) == nil else { return }
            state.order.append(key)
            if state.order.count > Self.limit {
                let oldest = state.order.removeFirst()
                state.byKey.removeValue(forKey: oldest)
                state.seqByKey.removeValue(forKey: oldest)
            }
        }
    }

    private func noteGroup(_ group: [String: Any]) {
        guard let session = group["sessionId"] as? String, let id = group["groupId"] as? String,
              let revision = (group["revision"] as? NSNumber)?.uint64Value,
              !session.contains("\u{0}"), !id.contains("\u{0}") else { return }
        var pending: [String: String] = [:]
        if group["state"] as? String == "pending" {
            for item in group["items"] as? [[String: Any]] ?? [] where item["state"] as? String == "pending" {
                guard let permission = item["permissionId"] as? String else { continue }
                pending[permission] = Self.groupAllow(item["request"] as? [String: Any])
            }
        }
        let key = session + "\u{0}" + id
        state.withLock { state in
            if let known = state.groups[key], known.revision > revision { return }
            if state.groups.updateValue(Group(revision: revision, pending: pending), forKey: key) == nil {
                state.groupOrder.append(key)
            }
            if state.groupOrder.count > Self.limit {
                state.groups.removeValue(forKey: state.groupOrder.removeFirst())
            }
        }
    }

    /// The first `allow_once` option the request offers once (acpmux `permission_groups::option`).
    private static func groupAllow(_ request: [String: Any]?) -> String {
        let options = request?["options"] as? [[String: Any]] ?? []
        let ids = options.compactMap { $0["optionId"] as? String }
        return options.first { option in
            guard option["kind"] as? String == "allow_once", let id = option["optionId"] as? String, !id.isEmpty else { return false }
            return ids.count(where: { $0 == id }) == 1
        }?["optionId"] as? String ?? ""
    }

    /// The newest read of group `id` of `session`.
    public func group(session: String, id: String) -> Group? {
        state.withLock { $0.groups[session + "\u{0}" + id] }
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The newest nonce and run of `permission` of `session`.
    public func context(session: String, permission: String) -> Context? {
        state.withLock { $0.byKey[session + "\u{0}" + permission] }
    }

    /// The daemon run this connection talks to directly (its own prompts need no relayed proof);
    /// nil for a chat on another machine (the wire's `initialize` names none).
    public var localInstance: String? { state.withLock { $0.localInstance } }

    /// The peer that refused an allow (one prompt's or a group's) for want of the person's proof
    /// since the last call, once.
    func takeRefusal() -> String? {
        state.withLock { state in
            defer { state.refusedBy = nil }
            return state.refusedBy
        }
    }

    /// A new connection: its daemon run and prompts are its own.
    func reset() { state.withLock { $0 = State() } }
}
