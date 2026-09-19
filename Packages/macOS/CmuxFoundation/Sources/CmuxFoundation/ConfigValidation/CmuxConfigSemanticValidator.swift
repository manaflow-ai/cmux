import CoreFoundation
public import Foundation

public enum CmuxConfigSemanticScope: String, Sendable {
    case global
    case project
}

public struct CmuxConfigSemanticIssue: Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Offline semantic validation for cmux.json.
///
/// The constraint vocabulary lives in web/data/cmux.schema.json and is embedded
/// into CmuxFoundation by scripts/generate-cmux-config-schema.py. Keep validation here
/// generic: adding a setting constraint belongs in the schema, not in another
/// command-specific lookup table.
public struct CmuxConfigSemanticValidator {
    public let scope: CmuxConfigSemanticScope

    private let rootSchema: [String: Any]

    public init(scope: CmuxConfigSemanticScope) {
        guard let object = try? JSONSerialization.jsonObject(
            with: CmuxEmbeddedConfigSchema.data,
            options: [.fragmentsAllowed]
        ),
        let rootSchema = object as? [String: Any] else {
            preconditionFailure("embedded cmux.json schema is not a JSON object")
        }
        self.scope = scope
        self.rootSchema = rootSchema
    }

    public func validate(jsonData data: Data) throws -> [CmuxConfigSemanticIssue] {
        let instance = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        return validate(jsonObject: instance)
    }

    public func validate(jsonObject instance: Any) -> [CmuxConfigSemanticIssue] {
        validate(
            instance,
            against: rootSchema,
            path: "$",
            tolerateUnknownProperties: usesFutureSchemaVersion(instance)
        )
    }

    private func validate(
        _ instance: Any,
        against schema: [String: Any],
        path: String,
        tolerateUnknownProperties: Bool
    ) -> [CmuxConfigSemanticIssue] {
        if scope == .project,
           let scopes = schema["x-cmux-scopes"] as? [String],
           !scopes.contains(CmuxConfigSemanticScope.project.rawValue) {
            return [
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.string(
                        "config.validation.scope.globalOnly",
                        defaultValue: "is only supported in the global cmux.json"
                    )
                )
            ]
        }

        var issues: [CmuxConfigSemanticIssue] = []

        if let ref = schema["$ref"] as? String {
            guard let target = resolvedReference(ref) else {
                return [
                    CmuxConfigSemanticIssue(
                        path: path,
                        message: CmuxConfigValidationLocalization.format(
                            "config.validation.schema.unknownReference",
                            defaultValue: "references an unknown schema definition '%@'",
                            ref
                        )
                    )
                ]
            }
            issues.append(
                contentsOf: validate(
                    instance,
                    against: target,
                    path: path,
                    tolerateUnknownProperties: tolerateUnknownProperties
                )
            )
        }

        if let typeSpec = schema["type"], !matchesType(instance, typeSpec: typeSpec) {
            return [
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.type.expected",
                        defaultValue: "expected %@, got %@",
                        typeDescription(typeSpec),
                        kindDescription(instance)
                    )
                )
            ]
        }

        if let constant = schema["const"], !jsonEqual(instance, constant) {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.value.equal",
                        defaultValue: "must equal %@",
                        displayJSON(constant)
                    )
                )
            )
        }

        if let choices = schema["enum"] as? [Any],
           !choices.contains(where: { jsonEqual(instance, $0) }) {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.value.oneOf",
                        defaultValue: "must be one of %@",
                        displayChoices(choices)
                    )
                )
            )
        }

        if let allOf = schema["allOf"] as? [Any] {
            for raw in allOf {
                guard let childSchema = raw as? [String: Any] else { continue }
                issues.append(
                    contentsOf: validate(
                        instance,
                        against: childSchema,
                        path: path,
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                )
            }
        }

        if let anyOf = schema["anyOf"] as? [Any] {
            let alternatives = anyOf.compactMap { $0 as? [String: Any] }
                .map {
                    validate(
                        instance,
                        against: $0,
                        path: path,
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                }
            if !alternatives.contains(where: \.isEmpty) {
                issues.append(
                    CmuxConfigSemanticIssue(
                        path: path,
                        message: CmuxConfigValidationLocalization.string(
                            "config.validation.form.none",
                            defaultValue: "does not match any allowed form"
                        )
                    )
                )
                if let best = alternatives.min(by: { $0.count < $1.count }) {
                    issues.append(contentsOf: best.prefix(2))
                }
            }
        }

        if let oneOf = schema["oneOf"] as? [Any] {
            let alternatives = oneOf.compactMap { $0 as? [String: Any] }
                .map {
                    validate(
                        instance,
                        against: $0,
                        path: path,
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                }
            let passing = alternatives.filter(\.isEmpty).count
            if passing != 1 {
                let message = passing == 0
                    ? CmuxConfigValidationLocalization.string(
                        "config.validation.form.none",
                        defaultValue: "does not match any allowed form"
                    )
                    : CmuxConfigValidationLocalization.string(
                        "config.validation.form.multiple",
                        defaultValue: "matches multiple mutually exclusive forms"
                    )
                issues.append(CmuxConfigSemanticIssue(path: path, message: message))
                if passing == 0,
                   let best = alternatives.min(by: { $0.count < $1.count }) {
                    issues.append(contentsOf: best.prefix(2))
                }
            }
        }

        if let condition = schema["if"] as? [String: Any],
           validate(
               instance,
               against: condition,
               path: path,
               tolerateUnknownProperties: tolerateUnknownProperties
           ).isEmpty,
           let thenSchema = schema["then"] as? [String: Any] {
            issues.append(
                contentsOf: validate(
                    instance,
                    against: thenSchema,
                    path: path,
                    tolerateUnknownProperties: tolerateUnknownProperties
                )
            )
        }

        if let forbidden = schema["not"] as? [String: Any],
           validate(
               instance,
               against: forbidden,
               path: path,
               tolerateUnknownProperties: tolerateUnknownProperties
           ).isEmpty {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.string(
                        "config.validation.form.disallowed",
                        defaultValue: "uses a disallowed value combination"
                    )
                )
            )
        }

        if let string = instance as? String {
            issues.append(contentsOf: validateString(string, schema: schema, path: path))
        } else if let number = jsonNumber(instance) {
            issues.append(contentsOf: validateNumber(number, schema: schema, path: path))
        } else if let array = instance as? [Any] {
            issues.append(
                contentsOf: validateArray(
                    array,
                    schema: schema,
                    path: path,
                    tolerateUnknownProperties: tolerateUnknownProperties
                )
            )
        } else if let object = instance as? [String: Any] {
            issues.append(
                contentsOf: validateObject(
                    object,
                    schema: schema,
                    path: path,
                    tolerateUnknownProperties: tolerateUnknownProperties
                )
            )
        }

        return deduplicated(issues)
    }

    private func validateString(
        _ value: String,
        schema: [String: Any],
        path: String
    ) -> [CmuxConfigSemanticIssue] {
        var issues: [CmuxConfigSemanticIssue] = []
        if let minimum = schemaInteger(schema["minLength"]), value.count < minimum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.string.min",
                        defaultValue: "must contain at least %lld character(s)",
                        Int64(minimum)
                    )
                )
            )
        }
        if let maximum = schemaInteger(schema["maxLength"]), value.count > maximum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.string.max",
                        defaultValue: "must contain at most %lld character(s)",
                        Int64(maximum)
                    )
                )
            )
        }
        if let pattern = schema["pattern"] as? String,
           !matchesPattern(value, pattern: pattern) {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.string.pattern",
                        defaultValue: "must match pattern %@",
                        displayJSON(pattern)
                    )
                )
            )
        }
        if let format = schema["format"] as? String, format == "uri" {
            let components = URLComponents(string: value)
            if components?.scheme?.isEmpty != false {
                issues.append(
                    CmuxConfigSemanticIssue(
                        path: path,
                        message: CmuxConfigValidationLocalization.string(
                            "config.validation.string.absoluteURI",
                            defaultValue: "must be an absolute URI"
                        )
                    )
                )
            }
        }
        return issues
    }

    private func validateNumber(
        _ value: Double,
        schema: [String: Any],
        path: String
    ) -> [CmuxConfigSemanticIssue] {
        var issues: [CmuxConfigSemanticIssue] = []
        if let minimum = schemaNumber(schema["minimum"]), value < minimum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.number.min",
                        defaultValue: "must be >= %@",
                        formatNumber(minimum)
                    )
                )
            )
        }
        if let maximum = schemaNumber(schema["maximum"]), value > maximum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.number.max",
                        defaultValue: "must be <= %@",
                        formatNumber(maximum)
                    )
                )
            )
        }
        if let minimum = schemaNumber(schema["exclusiveMinimum"]), value <= minimum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.number.gt",
                        defaultValue: "must be > %@",
                        formatNumber(minimum)
                    )
                )
            )
        }
        if let maximum = schemaNumber(schema["exclusiveMaximum"]), value >= maximum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.number.lt",
                        defaultValue: "must be < %@",
                        formatNumber(maximum)
                    )
                )
            )
        }
        if let multiple = schemaNumber(schema["multipleOf"]), multiple > 0 {
            let quotient = value / multiple
            let distance = abs(quotient - quotient.rounded())
            let tolerance = 1e-10 * max(1, abs(quotient))
            if distance > tolerance {
                issues.append(
                    CmuxConfigSemanticIssue(
                        path: path,
                        message: CmuxConfigValidationLocalization.format(
                            "config.validation.number.multiple",
                            defaultValue: "must be a multiple of %@",
                            formatNumber(multiple)
                        )
                    )
                )
            }
        }
        return issues
    }

    private func validateArray(
        _ value: [Any],
        schema: [String: Any],
        path: String,
        tolerateUnknownProperties: Bool
    ) -> [CmuxConfigSemanticIssue] {
        var issues: [CmuxConfigSemanticIssue] = []
        if let minimum = schemaInteger(schema["minItems"]), value.count < minimum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.array.min",
                        defaultValue: "must contain at least %lld item(s)",
                        Int64(minimum)
                    )
                )
            )
        }
        if let maximum = schemaInteger(schema["maxItems"]), value.count > maximum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.array.max",
                        defaultValue: "must contain at most %lld item(s)",
                        Int64(maximum)
                    )
                )
            )
        }

        let prefixSchemas = (schema["prefixItems"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let itemSchema = schema["items"] as? [String: Any]
        for (index, item) in value.enumerated() {
            if index < prefixSchemas.count {
                issues.append(
                    contentsOf: validate(
                        item,
                        against: prefixSchemas[index],
                        path: "\(path)[\(index)]",
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                )
            } else if let itemSchema {
                issues.append(
                    contentsOf: validate(
                        item,
                        against: itemSchema,
                        path: "\(path)[\(index)]",
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                )
            }
        }
        return issues
    }

    private func validateObject(
        _ value: [String: Any],
        schema: [String: Any],
        path: String,
        tolerateUnknownProperties: Bool
    ) -> [CmuxConfigSemanticIssue] {
        var issues: [CmuxConfigSemanticIssue] = []
        if let minimum = schemaInteger(schema["minProperties"]), value.count < minimum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.object.min",
                        defaultValue: "must contain at least %lld key(s)",
                        Int64(minimum)
                    )
                )
            )
        }
        if let maximum = schemaInteger(schema["maxProperties"]), value.count > maximum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization.format(
                        "config.validation.object.max",
                        defaultValue: "must contain at most %lld key(s)",
                        Int64(maximum)
                    )
                )
            )
        }

        if let required = schema["required"] as? [String] {
            for key in required where value[key] == nil {
                issues.append(
                    CmuxConfigSemanticIssue(
                        path: childPath(path, key: key),
                        message: CmuxConfigValidationLocalization.string(
                            "config.validation.required",
                            defaultValue: "is required"
                        )
                    )
                )
            }
        }

        let properties = schema["properties"] as? [String: Any] ?? [:]
        let patternProperties = schema["patternProperties"] as? [String: Any] ?? [:]
        let propertyNameSchema = schema["propertyNames"] as? [String: Any]
        let additional = schema["additionalProperties"]

        for key in value.keys.sorted() {
            let child = childPath(path, key: key)
            guard let childValue = value[key] else { continue }
            if let propertyNameSchema {
                issues.append(
                    contentsOf: validate(
                        key,
                        against: propertyNameSchema,
                        path: child,
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                )
            }

            var matchedPropertySchema = false
            if let propertySchema = properties[key] as? [String: Any] {
                issues.append(
                    contentsOf: validate(
                        childValue,
                        against: propertySchema,
                        path: child,
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                )
                matchedPropertySchema = true
            }
            for pattern in patternProperties.keys.sorted()
            where matchesPattern(key, pattern: pattern) {
                guard let patternSchema = patternProperties[pattern] as? [String: Any] else { continue }
                issues.append(
                    contentsOf: validate(
                        childValue,
                        against: patternSchema,
                        path: child,
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                )
                matchedPropertySchema = true
            }
            if matchedPropertySchema {
                continue
            }

            if let allowed = additional as? Bool, !allowed {
                if !tolerateUnknownProperties {
                    issues.append(
                        CmuxConfigSemanticIssue(
                            path: child,
                            message: CmuxConfigValidationLocalization.string(
                                "config.validation.unknownKey",
                                defaultValue: "unknown configuration key"
                            )
                        )
                    )
                }
            } else if let additionalSchema = additional as? [String: Any] {
                issues.append(
                    contentsOf: validate(
                        childValue,
                        against: additionalSchema,
                        path: child,
                        tolerateUnknownProperties: tolerateUnknownProperties
                    )
                )
            }
        }
        return issues
    }

    private func usesFutureSchemaVersion(_ instance: Any) -> Bool {
        guard let root = instance as? [String: Any],
              let configuredVersion = schemaInteger(root["schemaVersion"]),
              let properties = rootSchema["properties"] as? [String: Any],
              let versionSchema = properties["schemaVersion"] as? [String: Any],
              let currentVersion = schemaInteger(versionSchema["default"]) else {
            return false
        }
        return configuredVersion > currentVersion
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

}
