import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - V2 request/stream protocol
extension SocketClient {
    func sendV2(
        method: String,
        params: [String: Any] = [:],
        responseTimeout: TimeInterval? = nil
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 request")
        }

        let raw = try send(command: requestLine, responseTimeout: responseTimeout)

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
            let reason = error["reason"] as? String
            throw CLIError(
                message: formatV2Error(
                    code: code,
                    message: message,
                    action: action,
                    reason: reason,
                    details: safeV2Details(error["details"])
                )
            )
        }

        throw CLIError(message: "v2 request failed")
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

    func streamV2(
        method: String,
        params: [String: Any] = [:],
        onLine: (String) throws -> Void
    ) throws {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let requestData = try? JSONSerialization.data(withJSONObject: request, options: []),
              let requestLine = String(data: requestData, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 stream request")
        }

        try writeAll(
            Data((requestLine + "\n").utf8),
            timeoutMessage: "Stream request timed out",
            failureMessage: "Failed to write stream request"
        )

        while true {
            let line = try readStreamLine()
            try onLine(line)
        }
    }

    private func readStreamLine(maxBytes: Int = 4 * 1024 * 1024) throws -> String {
        var data = Data()
        try configureReceiveTimeout(45)
        while data.count < maxBytes {
            var byte: UInt8 = 0
            let count = Darwin.read(socketFD, &byte, 1)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: "Timed out waiting for event stream frame")
                }
                throw CLIError(message: "Event stream socket read error")
            }
            if count == 0 {
                throw CLIError(message: "Event stream closed")
            }
            if byte == 0x0A {
                guard let line = String(data: data, encoding: .utf8) else {
                    throw CLIError(message: "Invalid UTF-8 event stream frame")
                }
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            data.append(byte)
        }
        throw CLIError(message: "Event stream frame exceeded \(maxBytes) bytes")
    }
}
