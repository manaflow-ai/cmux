import Foundation

extension CmuxConfigSemanticValidator {
    func validateString(
        _ value: String,
        schema: [String: Any],
        path: String
    ) -> [CmuxConfigSemanticIssue] {
        var issues: [CmuxConfigSemanticIssue] = []
        if let minimum = schemaInteger(schema["minLength"]), value.count < minimum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
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
                        message: CmuxConfigValidationLocalization().string(
                            "config.validation.string.absoluteURI",
                            defaultValue: "must be an absolute URI"
                        )
                    )
                )
            }
        }
        return issues
    }

    func validateNumber(
        _ value: Double,
        schema: [String: Any],
        path: String
    ) -> [CmuxConfigSemanticIssue] {
        var issues: [CmuxConfigSemanticIssue] = []
        if let minimum = schemaNumber(schema["minimum"]), value < minimum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
                        "config.validation.number.lt",
                        defaultValue: "must be < %@",
                        formatNumber(maximum)
                    )
                )
            )
        }
        if let multiple = schemaNumber(schema["multipleOf"]), multiple > 0 {
            let remainder = abs(value.truncatingRemainder(dividingBy: multiple))
            let distance = min(remainder, multiple - remainder)
            // Permit only floating-point representation error, never a fraction
            // of the configured multiple. A quotient-scaled decimal tolerance
            // grows large enough to accept invalid values.
            let tolerance = max(value.ulp, multiple.ulp) * 4
            if distance > tolerance {
                issues.append(
                    CmuxConfigSemanticIssue(
                        path: path,
                        message: CmuxConfigValidationLocalization().format(
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

    func validateArray(
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
                    message: CmuxConfigValidationLocalization().format(
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
                    message: CmuxConfigValidationLocalization().format(
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

    func validateObject(
        _ value: [String: Any],
        schema: [String: Any],
        path: String,
        tolerateUnknownProperties: Bool
    ) -> [CmuxConfigSemanticIssue] {
        var issues: [CmuxConfigSemanticIssue] = []
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let patternProperties = schema["patternProperties"] as? [String: Any] ?? [:]
        let additional = schema["additionalProperties"]
        // Only a newer closed object can have genuinely unknown additions.
        // Open dictionaries still validate every entry, including name/count limits.
        let ignoresFutureKeys = tolerateUnknownProperties && (additional as? Bool) == false
        let constrainedKeys = value.keys.filter { key in
            !ignoresFutureKeys || properties[key] != nil
                || patternProperties.keys.contains { matchesPattern(key, pattern: $0) }
        }
        if let minimum = schemaInteger(schema["minProperties"]), constrainedKeys.count < minimum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization().format(
                        "config.validation.object.min",
                        defaultValue: "must contain at least %lld key(s)",
                        Int64(minimum)
                    )
                )
            )
        }
        if let maximum = schemaInteger(schema["maxProperties"]), constrainedKeys.count > maximum {
            issues.append(
                CmuxConfigSemanticIssue(
                    path: path,
                    message: CmuxConfigValidationLocalization().format(
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
                        message: CmuxConfigValidationLocalization().string(
                            "config.validation.required",
                            defaultValue: "is required"
                        )
                    )
                )
            }
        }

        let propertyNameSchema = schema["propertyNames"] as? [String: Any]

        for key in constrainedKeys.sorted() {
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
                            message: CmuxConfigValidationLocalization().string(
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
}
