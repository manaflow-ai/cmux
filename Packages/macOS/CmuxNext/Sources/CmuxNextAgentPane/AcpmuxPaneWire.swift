public import Foundation

/// The byte path under ``AcpmuxPaneSocket`` when it is not the local acpmux WebSocket: the frames
/// the host already checked go out through ``send(_:completion:)``, and the frames that come back
/// (acpmux JSON-RPC text) go through the same inbound checks and queues as the WebSocket's.
public nonisolated protocol AcpmuxPaneWire: Sendable {
    /// Opens the path. `onFrame` gets each inbound frame in order; `onClose` once, when the path
    /// ends by itself (never after ``cancel(code:reason:)``).
    func open(onFrame: @escaping @Sendable (String) -> Void,
              onClose: @escaping @Sendable (_ code: Int, _ reason: String) -> Void) async throws
    /// Sends one outbound frame; `completion` gets false when the path failed.
    func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void)
    /// Ends the path (the host's decision).
    func cancel(code: Int, reason: String)
}

/// A chat whose acpmux runs on another machine: the host's socket for it is a wire this route
/// makes (``RemoteAcpmuxWire`` over the owning session daemon), not a WebSocket to a local port.
/// Compared by identity.
public nonisolated final class AgentPaneRemoteRoute: Sendable {
    /// The machine's name, for logs (never a secret).
    public let machine: String
    private let make: @Sendable () -> any AcpmuxPaneWire

    public init(machine: String, make: @escaping @Sendable () -> any AcpmuxPaneWire) {
        self.machine = machine
        self.make = make
    }

    /// A fresh wire for one connection (each reconnect gets its own).
    public func makeWire() -> any AcpmuxPaneWire { make() }
}

extension AcpmuxConnection {
    /// The connection of a chat on another machine: no URL, no token; the wire carries it.
    nonisolated public static func remote(_ route: AgentPaneRemoteRoute) -> AcpmuxConnection {
        var connection = AcpmuxConnection(url: URL(fileURLWithPath: "/"), dashboardToken: "", localAppToken: nil)
        connection.remote = route
        return connection
    }
}
