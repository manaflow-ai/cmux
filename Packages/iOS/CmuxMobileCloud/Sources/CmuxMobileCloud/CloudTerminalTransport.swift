public import Foundation

/// The in-process tunnel a link dials through. Kept alive by every session
/// that used it; dropping the last reference tears the tunnel down.
public protocol CloudTunnel: AnyObject, Sendable {}

/// Starts an in-process WireGuard tunnel from wg-quick text.
public protocol CloudTunnelStarting: Sendable {
    /// Parses `wgQuickConfig` in memory and brings the tunnel up.
    func start(wgQuickConfig: String) async throws -> any CloudTunnel
}

/// One row of the daemon's terminal catalog.
public struct CloudTerminalSummary: Sendable, Equatable, Identifiable, Hashable {
    /// The daemon's terminal id.
    public var id: String
    /// The terminal's name, when it has one.
    public var name: String?

    /// Creates a row.
    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

/// Raw output from an attached terminal, in arrival order.
public enum CloudTerminalOutputEvent: Sendable, Equatable {
    /// Replay bytes for an emulator sized `cols` x `rows`.
    case snapshot(replay: Data, cols: Int, rows: Int)
    /// Live bytes after the snapshot.
    case output(Data)
    /// The daemon resized the terminal.
    case resized(cols: Int, rows: Int)
    /// The terminal's process ended.
    case exited
}

/// An authenticated link to one machine's daemon.
///
/// Methods block on the link, so conformers run them off the main actor.
public protocol CloudTerminalSession: AnyObject, Sendable {
    /// The daemon's terminals.
    func listTerminals() async throws -> [CloudTerminalSummary]
    /// Creates a workspace holding one terminal and returns the terminal id.
    func createTerminal(name: String?) async throws -> String
    /// Streams output for `terminalID` into `handler` until ``detach()``.
    /// The handler runs on library threads.
    func attach(terminalID: String, output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void) async throws
    /// Stops the current attachment.
    func detach()
    /// Queues input bytes for the attached terminal.
    func send(_ bytes: Data)
    /// Reports the phone's grid to the daemon.
    func resize(cols: Int, rows: Int)
    /// Closes the link.
    func disconnect()
}

/// Opens links with a persistent device identity.
public protocol CloudTerminalConnecting: Sendable {
    /// Connects to `route`, optionally through `tunnel`, and remembers the
    /// daemon under `stateDirectory` so later connects use the enrolled path.
    func connect(
        route: String,
        stateDirectory: URL,
        deviceName: String,
        invitation: String?,
        tunnel: (any CloudTunnel)?
    ) async throws -> any CloudTerminalSession
}
