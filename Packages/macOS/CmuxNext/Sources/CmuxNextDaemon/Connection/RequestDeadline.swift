import Foundation

/// The deadline of one request, and whether missing it is a terminal start's
/// (``DaemonError/terminalStartTimedOut(_:)``: the terminal may still appear).
struct RequestDeadline: Sendable {
    var timeout: Duration?
    var waitsForTerminalStart: Bool

    /// A control-plane request's deadline.
    static func control(_ timeout: Duration?) -> RequestDeadline {
        RequestDeadline(timeout: timeout, waitsForTerminalStart: false)
    }

    /// A ``TerminalSpawningRequest``'s deadline on the daemon `identity` names: the control deadline
    /// when that daemon answers it before the start (`terminal-async-start-v1`), else the terminal
    /// start deadline.
    ///
    /// - Parameters:
    ///   - repliesBeforeStart: ``TerminalSpawningRequest/repliesBeforeTerminalStart`` of the request.
    ///   - identity: The daemon that carries the request.
    ///   - configuration: The connection's deadlines.
    static func forSpawning(_ repliesBeforeStart: Bool, on identity: DaemonIdentity,
                            configuration: DaemonConnectionConfiguration) -> RequestDeadline {
        if repliesBeforeStart, identity.supports(DaemonCapability.terminalAsyncStart.rawValue) {
            return .control(configuration.requestTimeout)
        }
        return RequestDeadline(timeout: configuration.spawnTimeout, waitsForTerminalStart: true)
    }

    /// Sends `request` on `transport` within this deadline. A missed terminal start deadline throws
    /// ``DaemonError/terminalStartTimedOut(_:)``: cmux-tui keeps starting the terminal after the
    /// client gave up.
    func perform<R: DaemonRequest>(_ request: R, on transport: LineTransport) async throws -> R.Response {
        do {
            return try await DaemonConnection.perform(request, on: transport, timeout: timeout)
        } catch DaemonError.timedOut(let what) where waitsForTerminalStart {
            throw DaemonError.terminalStartTimedOut(what)
        }
    }
}
