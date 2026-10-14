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
    }

    static let limit = 256

    private struct State {
        var order: [String] = []
        var byKey: [String: Context] = [:]
        /// The log seq each context came from: an older page replayed later never wins.
        var seqByKey: [String: UInt64] = [:]
        var localInstance: String?
    }

    private let state = Mutex(State())

    public init() {}

    /// Reads one inbound frame, as the page gets it.
    func observe(_ object: [String: Any], replyTo method: String?) {
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
        state.withLock { state in
            if let seq, let known = state.seqByKey[key], seq < known { return }
            // An update without a seq is the newest the pane knows: no replayed record replaces it.
            state.seqByKey[key] = seq ?? .max
            guard state.byKey.updateValue(Context(nonce: nonce, instance: instance), forKey: key) == nil else { return }
            state.order.append(key)
            if state.order.count > Self.limit {
                let oldest = state.order.removeFirst()
                state.byKey.removeValue(forKey: oldest)
                state.seqByKey.removeValue(forKey: oldest)
            }
        }
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

    /// A new connection: its daemon run and prompts are its own.
    func reset() { state.withLock { $0 = State() } }
}
