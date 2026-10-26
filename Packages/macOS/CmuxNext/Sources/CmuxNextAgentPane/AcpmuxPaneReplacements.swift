public import Foundation
import CmuxNextCompat

/// Starts and opens of a chat in this pane (`session/new`, `session/load`, `session/resume`,
/// `_acpmux/attach`) that may still replace an unstarted new chat, so a Sandboxed send
/// (`sandbox.run`, hq#3367) is refused while any is out (``holds``). One is counted when it is sent,
/// by its parsed method (``sent(method:connection:)``), never by its text; `sandbox.run` is
/// admitted only once the pane's send line is drained (``AgentPaneTransport/lineDrained(within:)``),
/// so every start or open handed over before it has been sent or refused by then. It stops counting
/// when the daemon answers it with an error on its own connection (a definite failed open). A
/// success holds until the chat is adopted, after which the pane is no new chat. One sent on a
/// connection that has since closed stays counted: the daemon may still have taken it.
public nonisolated final class AcpmuxPaneReplacements: Sendable {
    private struct State {
        var waiting: [Int: Int] = [:]
        var opened = false
    }

    static let methods: Set<String> = ["session/new", "session/load", "session/resume", "_acpmux/attach"]
    private let state = Mutex(State())

    public init() {}

    /// A start or open is out or opened a chat here.
    public var holds: Bool { state.withLock { $0.opened || $0.waiting.values.contains { $0 > 0 } } }

    /// A frame with this parsed top-level `method` went out on `connection`.
    func sent(method: String?, connection: Int) {
        guard let method, Self.methods.contains(method) else { return }
        state.withLock { $0.waiting[connection, default: 0] += 1 }
    }

    /// Reads one daemon frame of `connection`, as the page gets it: the answer to a start or open.
    /// An answer counts against the connection it came on, so a late one from an older socket ends
    /// that socket's hold and no other.
    func observe(_ object: [String: Any], replyTo method: String?, connection: Int) {
        guard let method, Self.methods.contains(method), object["id"] != nil else { return }
        let opened = object["result"] != nil
        state.withLock { state in
            if let count = state.waiting[connection] { state.waiting[connection] = count > 1 ? count - 1 : nil }
            if opened { state.opened = true }
        }
    }

    /// For tests.
    func set(waiting: Int, opened: Bool = false, connection: Int = 0) {
        state.withLock { $0 = State(waiting: waiting > 0 ? [connection: waiting] : [:], opened: opened) }
    }
}
