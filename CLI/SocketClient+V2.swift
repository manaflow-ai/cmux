import Foundation
import CoreFoundation
import CmuxControlSocket
import Darwin

extension SocketClient {
    /// Maps a policy rejection shared by v1 and v2 requests to actionable CLI guidance.
    func checkSocketAccessDenied(_ response: String) throws {
        guard response.hasPrefix("ERROR:") else { return }
        let localizedAccessDeniedResponse = "ERROR: " + String(
            localized: "socket.client.accessDenied",
            defaultValue: "Access denied - only processes started inside cmux can connect",
            bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
        )
        if SocketStreamErrorKind.classify(
            line: response,
            localizedAccessDeniedResponse: localizedAccessDeniedResponse
        ) == .accessDenied {
            throw CLIError(message: String(
                localized: "cli.socket.error.connectionDenied",
                defaultValue: "cmux blocked this command before it ran. Run it from a cmux terminal, choose Automation mode in Settings > Automation > Socket Control Mode, or use an SSH link such as open -a cmux ssh://host from an external terminal.",
                bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
            ))
        }
    }

    func sendV2(
        method: String,
        params: [String: Any] = [:],
        responseTimeout: TimeInterval? = nil,
        deadline: Date? = nil
    ) throws -> [String: Any] {
        var tracedParams = params
        if method.hasPrefix("vm.") {
            for (key, env) in [("cloud_operation_id", "CMUX_CLOUD_OPERATION_ID"),
                               ("cloud_trace_id", "CMUX_CLOUD_TRACE_ID"),
                               ("cloud_parent_span_id", "CMUX_CLOUD_PARENT_SPAN_ID")] {
                if let value = ProcessInfo.processInfo.environment[env] { tracedParams[key] = value }
            }
        }
        let requestID = UUID().uuidString
        var request: [String: Any] = [
            "id": requestID,
            "method": method,
            "params": tracedParams
        ]
        if let ruleID = ProcessInfo.processInfo.environment["CMUX_AUTOMATION_RULE_ID"],
           !ruleID.isEmpty {
            request["automation_origin"] = Self.automationOriginPayload(ruleID: ruleID)
        }
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        // One total deadline includes every server-directed backoff and retry.
        let operationDeadline = min(
            deadline ?? .distantFuture,
            Date.now.addingTimeInterval(responseTimeout ?? Self.responseTimeoutSeconds)
        )
        let uptimeDeadline = ProcessInfo.processInfo.systemUptime + max(0, operationDeadline.timeIntervalSinceNow)
        while true {
            let raw = try send(command: requestLine, responseTimeout: responseTimeout, deadline: operationDeadline)

            // The server may return plain-text errors (e.g., "ERROR: Access denied ...")
            // before the JSON protocol starts. Surface these directly instead of letting
            // JSONSerialization throw a confusing parse error.
            if raw.hasPrefix("ERROR:") {
                throw CLIError(message: raw)
            }

            guard let responseData = raw.data(using: .utf8) else {
                throw CLIError(message: "Invalid UTF-8 v2 response")
            }
            guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
                throw CLIError(message: "Invalid v2 response: \(raw)")
            }

            if let ok = response["ok"] as? Bool, ok {
                return (response["result"] as? [String: Any]) ?? [:]
            }

            if let error = response["error"] as? [String: Any] {
                let code = (error["code"] as? String) ?? "error"
                let message = (error["message"] as? String) ?? "Unknown v2 error"
                let action = error["action"] as? String
                let data = error["data"] as? [String: Any]
                let failure = CLIError(
                    message: formatV2Error(
                        code: code,
                        message: message,
                        action: action,
                        reason: error["reason"] as? String,
                        details: safeV2Details(error["details"])
                    ),
                    v2Code: error["code"] as? String,
                    isStructuredProtocolResponse: true,
                    v2Retryable: data?["retryable"] as? Bool == true,
                    vmBackendCode: data?["backend_code"] as? String,
                    vmBackendHTTPStatus: (data?["http_status"] as? NSNumber)?.intValue
                )
                // Admission rejects these reads before dispatch. Mutations, relay
                // requests, transport failures, and malformed responses never retry.
                if !isRelayBacked,
                   response["ok"] as? Bool == false,
                   response["id"] as? String == requestID,
                   ControlCommandExecutionPolicy.pollingMethods.contains(method),
                   code == "rate_limited",
                   let delay = Self.pollingRetryDelay(data?["retry_after_ms"]),
                   delay < operationDeadline.timeIntervalSinceNow,
                   delay < uptimeDeadline - ProcessInfo.processInfo.systemUptime {
                    Self.waitForPollingAdmission(seconds: delay)
                    guard Date.now < operationDeadline,
                          ProcessInfo.processInfo.systemUptime < uptimeDeadline else {
                        throw failure
                    }
                    continue
                }
                throw failure
            }

            throw CLIError(message: "v2 request failed")
        }
    }

    private static func pollingRetryDelay(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let milliseconds = value as? Int, milliseconds > 0 else { return nil }
        return Double(milliseconds) / 1_000
    }

    /// A genuine server-requested delay on the CLI's existing synchronous socket
    /// path, never an app/main-actor wait. Monotonic time and EINTR handling keep
    /// signals from shortening admission backoff; the caller bounds it by the
    /// original request deadline. Migrating the blocking CLI transport to async
    /// is separate from honoring its protocol's backpressure contract.
    private static func waitForPollingAdmission(seconds: TimeInterval) {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            let remaining = until - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            var duration = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - remaining.rounded(.down)) * 1_000_000_000)
            )
            if nanosleep(&duration, nil) == 0 { return }
            if errno != EINTR { return }
        }
    }

    private func formatV2Error(
        code: String,
        message: String,
        action: String? = nil,
        reason: String? = nil,
        details: String? = nil
    ) -> String {
        let header: String
        if code == "vm_error" {
            header = message
        } else if message.contains("\n") {
            header = "\(code):\n\(message)"
        } else {
            header = "\(code): \(message)"
        }
        var sections = [header]
        if let reason = trimmedNonEmptyV2Text(reason) {
            sections.append("Reason:\n\(indentV2ErrorLines(reason))")
        }
        if let action = trimmedNonEmptyV2Text(action) {
            sections.append("What to do:\n\(indentV2ErrorLines(action))")
        }
        if let details = trimmedNonEmptyV2Text(details) {
            sections.append("Details:\n\(indentV2ErrorLines(details))")
        }
        return sections.joined(separator: "\n\n")
    }

    private func safeV2Details(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return trimmedNonEmptyV2Text(string)
        }
        if let dictionary = value as? [String: Any] {
            let allowedKeys = Set([
                "amount",
                "code",
                "duration",
                "durationMs",
                "field",
                "idempotencyKeySet",
                "imageRequested",
                "limit",
                "operation",
                "retryable",
                "status",
                "type",
                "vmId",
            ])
            let lines = dictionary.keys.sorted().compactMap { key -> String? in
                guard allowedKeys.contains(key), let value = dictionary[key], !(value is NSNull) else { return nil }
                return "\(key): \(safeV2DetailValue(value))"
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        return nil
    }

    private func safeV2DetailValue(_ value: Any) -> String {
        if let string = value as? String {
            return string.replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return "\(number)"
        }
        if value is [String: Any] || value is [Any] {
            return "available"
        }
        return String(describing: value)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private func trimmedNonEmptyV2Text(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func indentV2ErrorLines(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }

}
