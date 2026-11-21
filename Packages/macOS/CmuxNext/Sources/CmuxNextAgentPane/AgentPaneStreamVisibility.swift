import CmuxNextCompat

/// Whether anyone can see an agent pane, for the socket that carries its chat (``AcpmuxPaneSocket/setHidden(_:)``).
/// The pane's pacer owns it and sets it at each visibility change (``AgentPaneFramePacer/visibilityChanged()``);
/// each socket the transport opens attaches itself and starts from the current value. Sendable: the socket lives
/// off the main actor.
public nonisolated final class AgentPaneStreamVisibility: Sendable {
    private nonisolated struct State {
        var hidden = false
        weak var socket: AcpmuxPaneSocket?
    }

    private let state = Mutex(State())

    public init() {}

    /// The pane's socket from now on (a reconnect makes a new one); it is told the current value.
    func attach(_ socket: AcpmuxPaneSocket) {
        let hidden = state.withLock { state -> Bool in
            state.socket = socket
            return state.hidden
        }
        socket.setHidden(hidden)
    }

    /// Nobody sees the pane (`true`), or it shows again: told to the socket only when it changed.
    public func set(hidden: Bool) {
        let socket = state.withLock { state -> AcpmuxPaneSocket? in
            guard state.hidden != hidden else { return nil }
            state.hidden = hidden
            return state.socket
        }
        socket?.setHidden(hidden)
    }

    /// The last value set (tests).
    public var hidden: Bool { state.withLock { $0.hidden } }
}
