public import CmuxNextDaemon
public import CmuxNextSettings

/// The daemon's trace commands.
public protocol TraceDaemonLink: Sendable {
    /// Sends `command` and returns the daemon's reply (each process's ring path and bytes).
    func send(_ command: TraceControl.DaemonCommand) async throws -> CmuxNextSettings.JSONValue
}

/// The daemon's trace commands over the app's connection to it.
public struct DaemonTraceLink: TraceDaemonLink {
    private let connection: @Sendable () async -> DaemonConnection?

    /// - Parameter connection: The current daemon connection, nil while there is none.
    public init(connection: @escaping @Sendable () async -> DaemonConnection?) {
        self.connection = connection
    }

    public func send(_ command: TraceControl.DaemonCommand) async throws -> CmuxNextSettings.JSONValue {
        guard let connection = await connection() else { return TraceControl.untraced("not_connected") }
        switch command {
        case .start(let categories, let keys): return try await connection.request(StartRequest(categories: categories, keys: keys)).settingsJSON
        case .stop: return try await connection.request(StopRequest()).settingsJSON
        case .status: return try await connection.request(StatusRequest()).settingsJSON
        }
    }
}

extension DaemonTraceLink {
    /// `trace-start` (cmux-tui server/trace_control.rs `StartParams`).
    struct StartRequest: DaemonRequest {
        typealias Response = CmuxNextDaemon.JSONValue
        static let commandName: DaemonCommandName = "trace-start"
        let categories: [String]?
        let keys: Bool
    }

    /// `trace-stop`.
    struct StopRequest: DaemonRequest {
        typealias Response = CmuxNextDaemon.JSONValue
        static let commandName: DaemonCommandName = "trace-stop"
    }

    /// `trace-status`.
    struct StatusRequest: DaemonRequest {
        typealias Response = CmuxNextDaemon.JSONValue
        static let commandName: DaemonCommandName = "trace-status"
    }
}

extension CmuxNextDaemon.JSONValue {
    /// The same value as the control socket's JSON.
    var settingsJSON: CmuxNextSettings.JSONValue {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .array(let items): .array(items.map(\.settingsJSON))
        case .object(let members): .object(members.mapValues(\.settingsJSON))
        }
    }
}
