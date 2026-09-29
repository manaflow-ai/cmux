import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// Typed control errors for the cmux CLI compat layer. Codes match the old
/// app's (`not_found`, `invalid_params`) so CLI error handling keeps working;
/// `unsupported` is new and always says why.
enum CompatErrors {
    static let unsupportedCode = "unsupported"

    static func unsupported(_ reason: String, method: String? = nil) -> ControlError {
        var data: [String: JSON] = ["reason": .string(reason)]
        if let method { data["method"] = .string(method) }
        return ControlError(code: unsupportedCode, message: "unsupported in cmux-next: \(reason)", data: .object(data))
    }

    static func notFound(_ what: String, _ handle: String) -> ControlError {
        ControlError(code: "not_found", message: "\(what) not found: \(handle)", data: ["kind": .string(what), "handle": .string(handle)])
    }

    static func invalid(_ message: String) -> ControlError {
        ControlError(code: "invalid_params", message: message)
    }

    static func missing(_ param: String, _ method: String) -> ControlError {
        invalid("\(method) requires params.\(param)")
    }

    static let stopped = ControlError(code: "unavailable", message: "the control service stopped")

    static let notConnected = ControlError(code: "unavailable", message: "cmux-tui daemon is not connected yet")

    static func timeout(_ what: String, _ duration: Duration) -> ControlError {
        ControlError(code: "timeout", message: "\(what) did not finish within \(duration)")
    }

    /// Maps a daemon failure to a control error the CLI prints verbatim.
    static func from(_ error: any Error, doing what: String) -> ControlError {
        if let error = error as? ControlError { return error }
        guard let daemon = error as? DaemonError else {
            return ControlError(code: "internal_error", message: "\(what): \(error)")
        }
        switch daemon {
        case .notConnected, .connectionClosed: return notConnected
        case .missingCapabilities(let caps):
            return unsupported("the bundled cmux-tui lacks \(caps.joined(separator: ", ")) (needed for \(what))")
        case .command(_, let message, _):
            if message.hasPrefix("unknown ") || message.contains("not found") {
                return ControlError(code: "not_found", message: "\(what): \(message)")
            }
            if message.contains("unknown variant") {
                return unsupported("the bundled cmux-tui does not implement \(what)")
            }
            return ControlError(code: "daemon_error", message: "\(what): \(message)")
        default:
            return ControlError(code: "daemon_error", message: "\(what): \(daemon.description)")
        }
    }
}

/// Deadlines for cross-process and main-actor work (architecture.md 5a:
/// every call is async with a deadline; a miss is a typed error, never a
/// hang). The losing task is cancelled; work that cannot observe
/// cancellation finishes in the background without holding the caller.
enum CompatDeadline {
    static let controlPlane: Duration = .seconds(2)
    /// Browser script evaluation and page loads.
    static let browser: Duration = .seconds(10)

    static func run<T: Sendable>(
        _ what: String, within limit: Duration = controlPlane,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await ContinuousClock().sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CompatErrors.timeout(what, limit) }
            guard let value = first else { throw CompatErrors.timeout(what, limit) }
            return value
        }
    }
}
