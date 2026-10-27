public import Foundation
import CmuxNextCompat

/// Starts and opens of a chat in this pane (`session/new`, `session/load`, `session/resume`,
/// `_acpmux/attach`) that may still replace an unstarted new chat, so a Sandboxed send
/// (`sandbox.run`, hq#3367) is refused while any is out (``beginSandbox()``), and each is refused
/// while a Sandboxed send runs. One is counted before it is handed to the socket, by its decoded
/// method (``sending(method:connection:)``), never by its text, so its answer can't come first;
/// `sandbox.run` is admitted only once the pane's send line is drained
/// (``AgentPaneTransport/lineDrained(within:)``), so every start or open handed over before it has
/// been counted or refused by then. It stops counting when it isn't sent, or the daemon answers it
/// with an error on its own connection (a definite failed open). A success holds until the chat is
/// adopted, after which the pane is no new chat. One sent on a connection that has since closed
/// stays counted: the daemon may still have taken it. The check and the count are one step under
/// the lock, so a start and a Sandboxed send can't both pass.
public nonisolated final class AcpmuxPaneReplacements: Sendable {
    private struct State {
        var waiting: [Int: Int] = [:]
        var opened = false
        /// A Sandboxed send runs (``beginSandbox()`` to ``endSandbox()``).
        var sandbox = false
    }

    static let methods: Set<String> = ["session/new", "session/load", "session/resume", "_acpmux/attach"]
    private let state = Mutex(State())

    public init() {}

    /// A start or open is out or opened a chat here.
    public var holds: Bool { state.withLock { $0.opened || $0.waiting.values.contains { $0 > 0 } } }

    /// A frame with this decoded top-level `method` is about to go out on `connection`: a start or
    /// open is counted, or refused (false, nothing counted) while a Sandboxed send runs.
    func sending(method: String?, connection: Int) -> Bool {
        guard let method, Self.methods.contains(method) else { return true }
        return state.withLock { state in
            guard !state.sandbox else { return false }
            state.waiting[connection, default: 0] += 1
            return true
        }
    }

    /// A start or open that would be refused now, because a Sandboxed send runs: checked before the
    /// frame spends a gesture or a start credit, so a refused start uses neither. Counting it
    /// (``sending(method:connection:)``) still decides, under the lock.
    func refuses(method: String?) -> Bool {
        guard let method, Self.methods.contains(method) else { return false }
        return state.withLock { $0.sandbox }
    }

    /// A start or open ``sending(method:connection:)`` counted did not go out.
    func notSent(method: String?, connection: Int) {
        guard let method, Self.methods.contains(method) else { return }
        state.withLock { Self.drop(&$0, connection) }
    }

    /// Admits a Sandboxed send: false while a start or open is out or opened a chat, or one runs.
    /// Until ``endSandbox()`` every start or open is refused.
    func beginSandbox() -> Bool {
        state.withLock { state in
            guard !state.sandbox, !state.opened, !state.waiting.values.contains(where: { $0 > 0 }) else { return false }
            state.sandbox = true
            return true
        }
    }

    func endSandbox() {
        state.withLock { $0.sandbox = false }
    }

    private static func drop(_ state: inout State, _ connection: Int) {
        if let count = state.waiting[connection] { state.waiting[connection] = count > 1 ? count - 1 : nil }
    }

    /// Reads one daemon frame of `connection`, as the page gets it: the answer to a start or open.
    /// An answer counts against the connection it came on, so a late one from an older socket ends
    /// that socket's hold and no other.
    func observe(_ object: [String: Any], replyTo method: String?, connection: Int) {
        guard let method, Self.methods.contains(method), object["id"] != nil else { return }
        let opened = object["result"] != nil
        state.withLock { state in
            Self.drop(&state, connection)
            if opened { state.opened = true }
        }
    }

    /// For tests.
    func set(waiting: Int, opened: Bool = false, connection: Int = 0) {
        state.withLock { $0 = State(waiting: waiting > 0 ? [connection: waiting] : [:], opened: opened) }
    }
}
