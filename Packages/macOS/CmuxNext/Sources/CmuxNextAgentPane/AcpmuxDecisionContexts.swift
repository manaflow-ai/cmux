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
        guard object["method"] as? String == "_acpmux/permission_pending",
              let params = object["params"] as? [String: Any],
              let session = params["sessionId"] as? String, let permission = params["permissionId"] as? String,
              let nonce = params["decisionNonce"] as? String, let instance = params["personInstance"] as? String
        else { return }
        // A context that is not in acpmux's form is dropped: no proof is ever made over it.
        guard Self.isHex(nonce, count: 64), Self.isHex(instance, count: 32),
              !session.contains("\u{0}"), !permission.contains("\u{0}") else { return }
        let key = session + "\u{0}" + permission
        state.withLock { state in
            guard state.byKey.updateValue(Context(nonce: nonce, instance: instance), forKey: key) == nil else { return }
            state.order.append(key)
            if state.order.count > Self.limit { state.byKey.removeValue(forKey: state.order.removeFirst()) }
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
