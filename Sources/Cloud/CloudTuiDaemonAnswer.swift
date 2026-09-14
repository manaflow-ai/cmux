import Foundation

/// What a failed cmux-tui CLI invocation says about the daemon.
///
/// The raw command bridge prints one structured JSON error line when the daemon
/// rejects a request, and plain transport text when the daemon never answered.
/// A resolver must keep the two apart: a rejection is an authoritative answer
/// about the request, a transport failure says nothing about the terminal.
enum CloudTuiDaemonAnswer: Equatable, Sendable {
    /// The daemon answered and refused the request with this code.
    case rejected(String)
    /// No answer arrived: a connect or read timeout, a closed transport, the
    /// link's own deadline, a missing or unstartable client, or cancellation.
    case transportFailure(String)
    /// Failure text the app does not recognize.
    case unrecognized(String)

    init(error: any Error) {
        if error is CancellationError {
            self = .transportFailure("cancelled")
            return
        }
        guard let linkError = error as? CloudMachineLink.LinkError else {
            self = .unrecognized(CloudMachineLink.errorText(error))
            return
        }
        switch linkError {
        case .timedOut:
            self = .transportFailure("link deadline")
        case .clientMissing, .spawnFailed:
            self = .transportFailure(CloudMachineLink.errorText(linkError))
        case .inputTooLarge:
            self = .unrecognized(CloudMachineLink.errorText(linkError))
        case let .exited(_, output):
            self = Self.classify(output: output)
        }
    }

    /// Whether the daemon said it cannot serve this terminal id at all: the id
    /// is in the wrong space (`invalid_terminal_id`), unknown as a host id
    /// (`terminal_not_found`), or the daemon predates the resolver. The caller
    /// then reads the authoritative public snapshot instead of failing closed.
    var cannotServeTerminalID: Bool {
        guard case let .rejected(code) = self else { return false }
        return Self.unservableCodes.contains(code) || code.lowercased().contains("unknown command")
    }

    /// Whether retrying later can change the answer.
    var isRetryable: Bool {
        switch self {
        case .transportFailure, .unrecognized:
            return true
        case .rejected:
            return false
        }
    }

    /// One short reason for private diagnostic logs.
    var reason: String {
        switch self {
        case let .rejected(code):
            return code
        case let .transportFailure(text), let .unrecognized(text):
            return text
        }
    }

    var attachmentFailure: CloudTuiSurfaceIDResolution.Failure {
        switch self {
        case .transportFailure: return .transportUnavailable
        case .rejected: return .rejected
        case .unrecognized: return .invalidResponse
        }
    }

    /// The resource CLI resolves selectors before testing the revision fence.
    /// A raced deletion is therefore not necessarily a revision.conflict.
    static func isMissingSelector(_ error: Error) -> Bool {
        guard case let CloudMachineLink.LinkError.exited(_, output) = error else { return false }
        return output.split(whereSeparator: \.isNewline).contains { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["code"] as? String == "selector.not_found",
                  let details = object["details"] as? [String: Any],
                  details["scope"] is String, details["selector"] is String else { return false }
            return true
        }
    }

    private static let unservableCodes: Set<String> = [
        "invalid_terminal_id", "terminal_not_found", "operation.unsupported",
    ]

    private static let transportMarkers = [
        "transport timed out", "transport closed", "transport error",
        "cannot connect to session socket", "transport.timeout",
    ]

    private static func classify(output: String) -> Self {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let code = (object["code"] as? String) ?? (object["error_code"] as? String)
            if code == "operation.unsupported" { return .rejected("operation.unsupported") }
            if code == "transport.timeout" || code == "transport.closed" {
                return .transportFailure((object["message"] as? String) ?? code ?? "transport failure")
            }
            if let detail = (object["details"] as? [String: Any])?["error"] as? String, !detail.isEmpty {
                if detail == "transport.timeout" || detail == "transport.closed" {
                    return .transportFailure(detail)
                }
                return .rejected(detail)
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return .rejected(message)
            }
            if let code, !code.isEmpty { return .rejected(code) }
        }
        let text = lines.first?.trimmingCharacters(in: .whitespaces) ?? output
        let lowered = text.lowercased()
        if transportMarkers.contains(where: lowered.contains) {
            return .transportFailure(text)
        }
        return .unrecognized(text.isEmpty ? "cmux-tui exited without a reason" : text)
    }
}
