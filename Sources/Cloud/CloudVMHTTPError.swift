import Foundation

/// A Cloud VM HTTP failure rendered into the multi-line, user-facing diagnostic
/// string shown by `VMClientError.httpStatus`. Holds the HTTP status code and the
/// raw response body, parses the body as a JSON error envelope when possible, and
/// produces the formatted message via `formattedMessage`.
struct CloudVMHTTPError {
    let status: Int
    let body: String

    /// The multi-line, user-facing diagnostic for this HTTP failure. Falls back to
    /// a generic message plus the response body when the body is not a JSON object.
    var formattedMessage: String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmedBody.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return """
                Cloud VM request failed (HTTP \(status)).

                What to do:
                  Retry the command. If it keeps failing, copy the response body and contact support.

                Response body:
                  \(Self.limitedSingleLine(trimmedBody.isEmpty ? "<empty>" : trimmedBody))
                """
        }

        let errorCode = Self.string(object["error"]) ?? "http_\(status)"
        let message = Self.string(object["message"])
            ?? Self.string(object["reason"])
            ?? defaultMessage
        let action = Self.string(object["action"])
            ?? defaultAction(errorCode: errorCode)
        let details = Self.details(from: object)

        var lines: [String] = [
            "Cloud VM request failed (HTTP \(status): \(errorCode))",
            message,
        ]
        if !action.isEmpty {
            lines.append("")
            lines.append("What to do:")
            lines.append(contentsOf: Self.indentedActionLines(action))
        }
        if !details.isEmpty {
            lines.append("")
            lines.append("Details:")
            lines.append(contentsOf: details.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Generic human-readable message for this status when the body carries none.
    private var defaultMessage: String {
        switch status {
        case 400:
            return "The Cloud VM request was not valid."
        case 401:
            return "cmux could not authenticate this Cloud VM request."
        case 402:
            return "This team cannot create another Cloud VM with the current billing state."
        case 403:
            return "This Cloud VM request was not allowed."
        case 404:
            return "The requested Cloud VM was not found."
        case 409:
            return "Another Cloud VM operation is already running."
        case 500...599:
            return "The Cloud VM service is temporarily unavailable."
        default:
            return "The Cloud VM service returned an error."
        }
    }

    /// Suggested remediation for this status/error-code when the body carries none.
    private func defaultAction(errorCode: String) -> String {
        switch errorCode {
        case "vm_active_limit_exceeded":
            return "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before retrying."
        case "vm_not_found":
            return "Run `cmux vm ls` to see available Cloud VMs. If the VM was paused or destroyed, start a fresh one with `cmux vm new`."
        case "vm_billing_team_required":
            return "Select a team in cmux, then retry. You can also run `cmux auth status` to check the signed-in account."
        case "vm_create_credits_insufficient":
            return "Ask a team admin to upgrade the plan or grant more Cloud VM create credits, then retry."
        default:
            if status == 401 {
                return "Run `cmux auth login`, then retry."
            }
            if status == 403 {
                return "Run `cmux auth status` and confirm you are using the expected team."
            }
            return "Retry the command. If it keeps failing, copy this error and contact support."
        }
    }

    /// Allow-listed, sorted `key: value` detail lines extracted from the error envelope.
    private static func details(from object: [String: Any]) -> [String] {
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
        var details: [String: Any] = [:]
        func addAllowedDetail(key: String, value: Any) {
            guard allowedKeys.contains(key), !isNull(value) else { return }
            details[key] = value
        }
        if let rawDetails = object["details"] {
            if let nestedDetails = rawDetails as? [String: Any] {
                for (key, value) in nestedDetails {
                    addAllowedDetail(key: key, value: value)
                }
            }
        }
        for (key, value) in object {
            addAllowedDetail(key: key, value: value)
        }
        return details.keys.sorted().compactMap { key in
            guard let value = details[key], !isNull(value) else { return nil }
            return "\(key): \(valueDescription(value))"
        }
    }

    private static func indentedActionLines(_ action: String) -> [String] {
        action
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func valueDescription(_ value: Any) -> String {
        if let string = value as? String {
            return limitedSingleLine(string)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return "\(number)"
        }
        if isNull(value) {
            return "null"
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            return limitedSingleLine(encoded)
        }
        return limitedSingleLine(String(describing: value))
    }

    private static func isNull(_ value: Any) -> Bool {
        value is NSNull
    }

    // maxCharacters is measured in Swift Characters so truncation never splits a grapheme cluster.
    private static func limitedSingleLine(_ value: String, maxCharacters: Int = 1200) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard singleLine.count > maxCharacters else { return singleLine }
        let index = singleLine.index(singleLine.startIndex, offsetBy: maxCharacters)
        return String(singleLine[..<index]) + "..."
    }
}
