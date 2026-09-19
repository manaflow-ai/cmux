import CoreFoundation
import Foundation
import CmuxFoundation

enum CMUXConfigSemanticScope: String {
    case global
    case project
}

struct CMUXConfigSemanticIssue: Equatable {
    let path: String
    let message: String

    var payload: [String: Any] {
        ["path": path, "message": message]
    }
}

/// Offline semantic validation for cmux.json.
///
/// The constraint vocabulary lives in web/data/cmux.schema.json and is embedded
/// into the CLI by scripts/generate-cmux-config-schema.py. Keep validation here
/// generic: adding a setting constraint belongs in the schema, not in another
/// command-specific lookup table.
struct CMUXConfigSemanticValidator {
    let scope: CMUXConfigSemanticScope

    private let rootSchema: [String: Any]

    init(scope: CMUXConfigSemanticScope) throws {
        let object = try JSONSerialization.jsonObject(
            with: CMUXEmbeddedConfigSchema.data,
            options: [.fragmentsAllowed]
        )
        guard let rootSchema = object as? [String: Any] else {
            throw CLIError(message: "Embedded cmux.json schema is not a JSON object")
        }
        self.scope = scope
        self.rootSchema = rootSchema
    }

    func validate(data: Data) throws -> [CMUXConfigSemanticIssue] {
        let sanitized = try JSONCParser.preprocess(data: data)
        let instance = try JSONSerialization.jsonObject(
            with: sanitized,
            options: [.fragmentsAllowed]
        )
        return validate(instance, against: rootSchema, path: "$")
    }

    private func validate(
        _ instance: Any,
        against schema: [String: Any],
        path: String
    ) -> [CMUXConfigSemanticIssue] {
        if scope == .project,
           let scopes = schema["x-cmux-scopes"] as? [String],
           !scopes.contains(CMUXConfigSemanticScope.project.rawValue) {
            return [
                CMUXConfigSemanticIssue(
                    path: path,
                    message: "is only supported in the global cmux.json"
                )
            ]
        }

        var issues: [CMUXConfigSemanticIssue] = []

        if let ref = schema["$ref"] as? String {
            guard let target = resolvedReference(ref) else {
                return [CMUXConfigSemanticIssue(path: path, message: "references an unknown schema definition '\(ref)'")]
            }
            issues.append(contentsOf: validate(instance, against: target, path: path))
        }

        if let typeSpec = schema["type"], !matchesType(instance, typeSpec: typeSpec) {
            return [
                CMUXConfigSemanticIssue(
                    path: path,
                    message: "expected \(typeDescription(typeSpec)), got \(kindDescription(instance))"
                )
            ]
        }

        if let constant = schema["const"], !jsonEqual(instance, constant) {
            issues.append(
                CMUXConfigSemanticIssue(
                    path: path,
                    message: "must equal \(displayJSON(constant))"
                )
            )
        }

        if let choices = schema["enum"] as? [Any],
           !choices.contains(where: { jsonEqual(instance, $0) }) {
            issues.append(
                CMUXConfigSemanticIssue(
                    path: path,
                    message: "must be one of \(displayChoices(choices))"
                )
            )
        }

        if let allOf = schema["allOf"] as? [Any] {
            for raw in allOf {
                guard let childSchema = raw as? [String: Any] else { continue }
                issues.append(contentsOf: validate(instance, against: childSchema, path: path))
            }
        }

        if let anyOf = schema["anyOf"] as? [Any] {
            let alternatives = anyOf.compactMap { $0 as? [String: Any] }
                .map { validate(instance, against: $0, path: path) }
            if !alternatives.contains(where: \.isEmpty) {
                issues.append(CMUXConfigSemanticIssue(path: path, message: "does not match any allowed form"))
                if let best = alternatives.min(by: { $0.count < $1.count }) {
                    issues.append(contentsOf: best.prefix(2))
                }
            }
        }

        if let oneOf = schema["oneOf"] as? [Any] {
            let alternatives = oneOf.compactMap { $0 as? [String: Any] }
                .map { validate(instance, against: $0, path: path) }
            let passing = alternatives.filter(\.isEmpty).count
            if passing != 1 {
                let message = passing == 0
                    ? "does not match any allowed form"
                    : "matches multiple mutually exclusive forms"
                issues.append(CMUXConfigSemanticIssue(path: path, message: message))
                if passing == 0,
                   let best = alternatives.min(by: { $0.count < $1.count }) {
                    issues.append(contentsOf: best.prefix(2))
                }
            }
        }

        if let condition = schema["if"] as? [String: Any],
           validate(instance, against: condition, path: path).isEmpty,
           let thenSchema = schema["then"] as? [String: Any] {
            issues.append(contentsOf: validate(instance, against: thenSchema, path: path))
        }

        if let forbidden = schema["not"] as? [String: Any],
           validate(instance, against: forbidden, path: path).isEmpty {
            issues.append(
                CMUXConfigSemanticIssue(
                    path: path,
                    message: "uses a disallowed value combination"
                )
            )
        }

        if let string = instance as? String {
            issues.append(contentsOf: validateString(string, schema: schema, path: path))
        } else if let number = jsonNumber(instance) {
            issues.append(contentsOf: validateNumber(number, schema: schema, path: path))
        } else if let array = instance as? [Any] {
            issues.append(contentsOf: validateArray(array, schema: schema, path: path))
        } else if let object = instance as? [String: Any] {
            issues.append(contentsOf: validateObject(object, schema: schema, path: path))
        }

        return deduplicated(issues)
    }

    private func validateString(
        _ value: String,
        schema: [String: Any],
        path: String
    ) -> [CMUXConfigSemanticIssue] {
        var issues: [CMUXConfigSemanticIssue] = []
        if let minimum = schemaInteger(schema["minLength"]), value.count < minimum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must contain at least \(minimum) character(s)"))
        }
        if let maximum = schemaInteger(schema["maxLength"]), value.count > maximum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must contain at most \(maximum) character(s)"))
        }
        if let pattern = schema["pattern"] as? String,
           !matchesPattern(value, pattern: pattern) {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must match pattern \(displayJSON(pattern))"))
        }
        if let format = schema["format"] as? String, format == "uri" {
            let components = URLComponents(string: value)
            if components?.scheme?.isEmpty != false {
                issues.append(CMUXConfigSemanticIssue(path: path, message: "must be an absolute URI"))
            }
        }
        return issues
    }

    private func validateNumber(
        _ value: Double,
        schema: [String: Any],
        path: String
    ) -> [CMUXConfigSemanticIssue] {
        var issues: [CMUXConfigSemanticIssue] = []
        if let minimum = schemaNumber(schema["minimum"]), value < minimum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must be >= \(formatNumber(minimum))"))
        }
        if let maximum = schemaNumber(schema["maximum"]), value > maximum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must be <= \(formatNumber(maximum))"))
        }
        if let minimum = schemaNumber(schema["exclusiveMinimum"]), value <= minimum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must be > \(formatNumber(minimum))"))
        }
        if let maximum = schemaNumber(schema["exclusiveMaximum"]), value >= maximum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must be < \(formatNumber(maximum))"))
        }
        return issues
    }

    private func validateArray(
        _ value: [Any],
        schema: [String: Any],
        path: String
    ) -> [CMUXConfigSemanticIssue] {
        var issues: [CMUXConfigSemanticIssue] = []
        if let minimum = schemaInteger(schema["minItems"]), value.count < minimum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must contain at least \(minimum) item(s)"))
        }
        if let maximum = schemaInteger(schema["maxItems"]), value.count > maximum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must contain at most \(maximum) item(s)"))
        }

        let prefixSchemas = (schema["prefixItems"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let itemSchema = schema["items"] as? [String: Any]
        for (index, item) in value.enumerated() {
            if index < prefixSchemas.count {
                issues.append(contentsOf: validate(item, against: prefixSchemas[index], path: "\(path)[\(index)]"))
            } else if let itemSchema {
                issues.append(contentsOf: validate(item, against: itemSchema, path: "\(path)[\(index)]"))
            }
        }
        return issues
    }

    private func validateObject(
        _ value: [String: Any],
        schema: [String: Any],
        path: String
    ) -> [CMUXConfigSemanticIssue] {
        var issues: [CMUXConfigSemanticIssue] = []
        if let minimum = schemaInteger(schema["minProperties"]), value.count < minimum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must contain at least \(minimum) key(s)"))
        }
        if let maximum = schemaInteger(schema["maxProperties"]), value.count > maximum {
            issues.append(CMUXConfigSemanticIssue(path: path, message: "must contain at most \(maximum) key(s)"))
        }

        if let required = schema["required"] as? [String] {
            for key in required where value[key] == nil {
                issues.append(CMUXConfigSemanticIssue(path: childPath(path, key: key), message: "is required"))
            }
        }

        let properties = schema["properties"] as? [String: Any] ?? [:]
        let propertyNameSchema = schema["propertyNames"] as? [String: Any]
        let additional = schema["additionalProperties"]

        for key in value.keys.sorted() {
            let child = childPath(path, key: key)
            if let propertyNameSchema {
                issues.append(contentsOf: validate(key, against: propertyNameSchema, path: child))
            }
            if let propertySchema = properties[key] as? [String: Any],
               let childValue = value[key] {
                issues.append(contentsOf: validate(childValue, against: propertySchema, path: child))
                continue
            }
            if let allowed = additional as? Bool, !allowed {
                issues.append(CMUXConfigSemanticIssue(path: child, message: "unknown configuration key"))
            } else if let additionalSchema = additional as? [String: Any],
                      let childValue = value[key] {
                issues.append(contentsOf: validate(childValue, against: additionalSchema, path: child))
            }
        }
        return issues
    }

    private func resolvedReference(_ ref: String) -> [String: Any]? {
        guard ref.hasPrefix("#/") else { return nil }
        var current: Any = rootSchema
        for component in ref.dropFirst(2).split(separator: "/") {
            let key = component
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current as? [String: Any]
    }

    private func matchesType(_ value: Any, typeSpec: Any) -> Bool {
        if let type = typeSpec as? String {
            return matchesType(value, type: type)
        }
        if let types = typeSpec as? [String] {
            return types.contains { matchesType(value, type: $0) }
        }
        return true
    }

    private func matchesType(_ value: Any, type: String) -> Bool {
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

    private func typeDescription(_ typeSpec: Any) -> String {
        if let type = typeSpec as? String { return type }
        if let types = typeSpec as? [String] { return types.joined(separator: " or ") }
        return "valid JSON value"
    }

    private func kindDescription(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if isJSONBoolean(value) { return "boolean" }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        if let number = jsonNumber(value) {
            return number.rounded() == number ? "integer" : "number"
        }
        return String(describing: type(of: value))
    }

    private func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func jsonNumber(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, !isJSONBoolean(value) else { return nil }
        return number.doubleValue
    }

    private func schemaNumber(_ value: Any?) -> Double? {
        guard let value else { return nil }
        return jsonNumber(value)
    }

    private func schemaInteger(_ value: Any?) -> Int? {
        guard let value, let number = jsonNumber(value), number.isFinite else { return nil }
        return Int(exactly: number)
    }

    private func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
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
            return left.allSatisfy { key, value in
                guard let other = right[key] else { return false }
                return jsonEqual(value, other)
            }
        }
        return false
    }

    private func matchesPattern(_ value: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private func childPath(_ path: String, key: String) -> String {
        let simple = key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
        if simple {
            return "\(path).\(key)"
        }
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "\(path)['\(escaped)']"
    }

    private func displayChoices(_ values: [Any]) -> String {
        let rendered = values.prefix(8).map(displayJSON)
        if values.count > rendered.count {
            return rendered.joined(separator: ", ") + " (+\(values.count - rendered.count) more)"
        }
        return rendered.joined(separator: ", ")
    }

    private func displayJSON(_ value: Any) -> String {
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

    private func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    private func deduplicated(_ issues: [CMUXConfigSemanticIssue]) -> [CMUXConfigSemanticIssue] {
        var seen = Set<String>()
        return issues.filter { issue in
            seen.insert("\(issue.path)\u{0}\(issue.message)").inserted
        }
    }
}
