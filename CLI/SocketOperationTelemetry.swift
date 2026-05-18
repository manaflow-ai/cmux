import Foundation

struct CLISocketOperationTelemetry {
    enum Phase: String {
        case writeRequest = "write_request"
        case waitForResponse = "wait_for_response"
        case readMultilineResponse = "read_multiline_response"
        case completed
    }

    struct State {
        let name: String
        var timeout: TimeInterval
        let startedAt: Date
        var phase: Phase
        var bytesRead: Int = 0
        var sawNewline = false

        func context() -> [String: Any] {
            [
                "socket_operation": name,
                "socket_phase": phase.rawValue,
                "socket_timeout_seconds": timeout,
                "socket_duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                "socket_bytes_read": bytesRead,
                "socket_saw_newline": sawNewline,
            ]
        }
    }

    static func operationName(for command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "unknown"
        }

        if trimmed.hasPrefix("{") {
            guard
                let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let method = (object["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !method.isEmpty
            else {
                return "unknown"
            }
            return method
        }

        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first.map(String.init) ?? "unknown"
    }
}
