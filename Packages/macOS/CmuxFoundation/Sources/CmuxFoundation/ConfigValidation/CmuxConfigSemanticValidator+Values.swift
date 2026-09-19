import CoreFoundation
import Foundation

extension CmuxConfigSemanticValidator {
    func matchesType(_ value: Any, typeSpec: Any) -> Bool {
        if let type = typeSpec as? String {
            return matchesType(value, type: type)
        }
        if let types = typeSpec as? [String] {
            return types.contains { matchesType(value, type: $0) }
        }
        return true
    }

    func matchesType(_ value: Any, type: String) -> Bool {
        switch type {
        case "null":
            return value is NSNull
        case "boolean":
            return isJSONBoolean(value)
        case "string":
            return value is String
        case "array":
            return value is [Any]
        case "object":
            return value is [String: Any]
        case "number":
            return jsonNumber(value) != nil
        case "integer":
            guard let number = jsonNumber(value), number.isFinite else { return false }
            return number.rounded() == number
        default:
            return true
        }
    }

    func typeDescription(_ typeSpec: Any) -> String {
        if let type = typeSpec as? String {
            return localizedType(type)
        }
        if let types = typeSpec as? [String] {
            return types.map(localizedType).joined(separator: " / ")
        }
        return CmuxConfigValidationLocalization.string(
            "config.validation.type.jsonValue",
            defaultValue: "valid JSON value"
        )
    }

    func kindDescription(_ value: Any) -> String {
        if value is NSNull { return localizedType("null") }
        if isJSONBoolean(value) { return localizedType("boolean") }
        if value is String { return localizedType("string") }
        if value is [Any] { return localizedType("array") }
        if value is [String: Any] { return localizedType("object") }
        if let number = jsonNumber(value) {
            return localizedType(number.rounded() == number ? "integer" : "number")
        }
        return String(describing: type(of: value))
    }

    func localizedType(_ type: String) -> String {
        switch type {
        case "null":
            return CmuxConfigValidationLocalization.string(
                "config.validation.type.null",
                defaultValue: "null"
            )
        case "boolean":
            return CmuxConfigValidationLocalization.string(
                "config.validation.type.boolean",
                defaultValue: "boolean"
            )
        case "string":
            return CmuxConfigValidationLocalization.string(
                "config.validation.type.string",
                defaultValue: "string"
            )
        case "array":
            return CmuxConfigValidationLocalization.string(
                "config.validation.type.array",
                defaultValue: "array"
            )
        case "object":
            return CmuxConfigValidationLocalization.string(
                "config.validation.type.object",
                defaultValue: "object"
            )
        case "number":
            return CmuxConfigValidationLocalization.string(
                "config.validation.type.number",
                defaultValue: "number"
            )
        case "integer":
            return CmuxConfigValidationLocalization.string(
                "config.validation.type.integer",
                defaultValue: "integer"
            )
        default:
            return type
        }
    }

    func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    func jsonNumber(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, !isJSONBoolean(value) else { return nil }
        return number.doubleValue
    }

    func schemaNumber(_ value: Any?) -> Double? {
        guard let value else { return nil }
        return jsonNumber(value)
    }

    func schemaInteger(_ value: Any?) -> Int? {
        guard let value, let number = jsonNumber(value), number.isFinite else { return nil }
        return Int(exactly: number)
    }

    func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull || rhs is NSNull {
            return lhs is NSNull && rhs is NSNull
        }
        if isJSONBoolean(lhs) || isJSONBoolean(rhs) {
            guard isJSONBoolean(lhs), isJSONBoolean(rhs),
                  let left = lhs as? NSNumber,
                  let right = rhs as? NSNumber else {
                return false
            }
            return left.boolValue == right.boolValue
        }
        if let left = lhs as? String, let right = rhs as? String {
            return left == right
        }
        if let left = jsonNumber(lhs), let right = jsonNumber(rhs) {
            return left == right
        }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            return left.count == right.count && zip(left, right).allSatisfy { pair in
                jsonEqual(pair.0, pair.1)
            }
        }
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            guard Set(left.keys) == Set(right.keys) else { return false }
            return left.allSatisfy { entry in
                guard let other = right[entry.key] else { return false }
                return jsonEqual(entry.value, other)
            }
        }
        return false
    }

    func matchesPattern(_ value: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return expression.firstMatch(in: value, range: range) != nil
    }

    func childPath(_ path: String, key: String) -> String {
        let simple = key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
        if simple {
            return "\(path).\(key)"
        }
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "\(path)['\(escaped)']"
    }

    func displayChoices(_ values: [Any]) -> String {
        let rendered = values.prefix(8).map(displayJSON)
        if values.count > rendered.count {
            let suffix = CmuxConfigValidationLocalization.format(
                "config.validation.choices.more",
                defaultValue: "(+%lld more)",
                Int64(values.count - rendered.count)
            )
            return rendered.joined(separator: ", ") + " " + suffix
        }
        return rendered.joined(separator: ", ")
    }

    func displayJSON(_ value: Any) -> String {
        if let string = value as? String {
            if let data = try? JSONSerialization.data(withJSONObject: [string]),
               let encoded = String(data: data, encoding: .utf8) {
                return String(encoded.dropFirst().dropLast())
            }
            return "\"\(string)\""
        }
        if value is NSNull { return "null" }
        if isJSONBoolean(value), let number = value as? NSNumber {
            return number.boolValue ? "true" : "false"
        }
        if let number = jsonNumber(value) {
            return formatNumber(number)
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return String(describing: value)
    }

    func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    func deduplicated(_ issues: [CmuxConfigSemanticIssue]) -> [CmuxConfigSemanticIssue] {
        var seen = Set<String>()
        return issues.filter { issue in
            seen.insert("\(issue.path)\u{0}\(issue.message)").inserted
        }
    }
}
