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
    /// when the request asked that daemon to answer before the start (`async_start` on a
    /// `terminal-async-start-v1` daemon), else the terminal start deadline.
    ///
    /// - Parameters:
    ///   - asksAsyncStart: ``TerminalSpawningRequest/asksAsyncStart`` of the request.
    ///   - identity: The daemon that carries the request.
    ///   - configuration: The connection's deadlines.
    static func forSpawning(_ asksAsyncStart: Bool, on identity: DaemonIdentity,
                            configuration: DaemonConnectionConfiguration) -> RequestDeadline {
        if asksAsyncStart, identity.supports(DaemonCapability.terminalAsyncStart.rawValue) {
            return .control(configuration.requestTimeout)
        }
        return RequestDeadline(timeout: configuration.spawnTimeout, waitsForTerminalStart: true)
    }

    /// The deadline of `request` by whether it asks to be answered at admit (``TerminalSpawningRequest/asksAsyncStart``).
    static func forSpawning<R: DaemonRequest>(_ request: R, on identity: DaemonIdentity,
                                              configuration: DaemonConnectionConfiguration) -> RequestDeadline {
        forSpawning((request as? any TerminalSpawningRequest)?.asksAsyncStart == true, on: identity, configuration: configuration)
    }

    /// `request` for the daemon `identity` names: without its `async_start` ask when that daemon does
    /// not serve `terminal-async-start-v1` (a request held through a handoff to an older daemon).
    static func served<R: DaemonRequest>(_ request: R, by identity: DaemonIdentity) -> R {
        guard !identity.supports(DaemonCapability.terminalAsyncStart.rawValue),
              let spawning = request as? any TerminalSpawningRequest, spawning.asksAsyncStart,
              let plain = spawning.withoutAsyncStart() as? R else { return request }
        return plain
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
