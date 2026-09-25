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
        self.init(scope: scope, schema: .embedded)
    }

    init(scope: CmuxConfigSemanticScope, schema: CmuxParsedConfigSchema) {
        self.scope = scope
        self.rootSchema = schema.root
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

    func validate(
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
                    message: CmuxConfigValidationLocalization().string(
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
                        message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
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
                        message: CmuxConfigValidationLocalization().string(
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
                    ? CmuxConfigValidationLocalization().string(
                        "config.validation.form.none",
                        defaultValue: "does not match any allowed form"
                    )
                    : CmuxConfigValidationLocalization().string(
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
                    message: CmuxConfigValidationLocalization().string(
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
