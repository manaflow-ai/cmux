import Foundation

extension CmuxAgentManifestCodec {
    enum ObjectKind: Sendable {
        case manifest, process, matcher, state, regex, osc, session, restorable
    }

    /// Rejects unknown fields and invalid container shapes before decoding.
    static func validateKeys(in object: Any, kind: ObjectKind, path: String) throws {
        guard let dictionary = object as? [String: Any] else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.mustBeObject",
                    defaultValue: "Must be an object"
                )
            )
        }
        let allowed: Set<String>
        switch kind {
        case .manifest: allowed = ["schemaVersion", "id", "displayName", "iconAssetName", "process", "states", "session", "restorableWhen", "mergeStrategy"]
        case .process: allowed = ["matchers"]
        case .matcher: allowed = ["id", "processNames", "processPathContains", "processPathRegex", "argvContainsAll", "argvContainsAny", "argvBasenamesAny", "environmentEquals"]
        case .state: allowed = ["id", "state", "screenContains", "screenRegex", "osc", "oscSequences"]
        case .regex: allowed = ["pattern", "caseInsensitive", "dotMatchesNewlines"]
        case .osc: allowed = ["sequence", "mode"]
        case .session: allowed = ["sessionIdSource", "resumeCommand", "forkCommand", "cwd", "sessionDirectory"]
        case .restorable: allowed = ["environmentEquals"]
        }
        for key in dictionary.keys where !allowed.contains(key) {
            throw CmuxAgentManifestValidationError(
                path: path.isEmpty ? key : "\(path).\(key)",
                reason: localizedReason(
                    "agentManifest.validation.unknownField",
                    defaultValue: "Unknown manifest field"
                )
            )
        }
        for (key, value) in dictionary {
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            guard !(value is NSNull) else {
                throw CmuxAgentManifestValidationError(
                    path: childPath,
                    reason: localizedReason(
                        "agentManifest.validation.notNull",
                        defaultValue: "Must not be null"
                    )
                )
            }
            switch (kind, key) {
            case (.manifest, "mergeStrategy"):
                guard let rawStrategy = value as? String else {
                    throw CmuxAgentManifestValidationError(
                        path: childPath,
                        reason: localizedReason(
                            "agentManifest.validation.overlayOrReplace",
                            defaultValue: "Must be either 'overlay' or 'replace'"
                        )
                    )
                }
                let strategy = rawStrategy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard strategy == "overlay" || strategy == "replace" else {
                    throw CmuxAgentManifestValidationError(
                        path: childPath,
                        reason: localizedReason(
                            "agentManifest.validation.overlayOrReplace",
                            defaultValue: "Must be either 'overlay' or 'replace'"
                        )
                    )
                }
            case (.manifest, "process"): try validateKeys(in: value, kind: .process, path: childPath)
            case (.manifest, "states"): try validateArray(value, kind: .state, path: childPath)
            case (.manifest, "session"): try validateKeys(in: value, kind: .session, path: childPath)
            case (.manifest, "restorableWhen"): try validateKeys(in: value, kind: .restorable, path: childPath)
            case (.process, "matchers"): try validateArray(value, kind: .matcher, path: childPath)
            case (.matcher, "processNames"),
                 (.matcher, "processPathContains"),
                 (.matcher, "argvContainsAll"),
                 (.matcher, "argvContainsAny"),
                 (.matcher, "argvBasenamesAny"),
                 (.state, "screenContains"):
                try validateStringArrayOrString(value, path: childPath)
            case (.matcher, "processPathRegex"):
                try validateArray(value, kind: .regex, path: childPath, allowStrings: true)
            case (.matcher, "environmentEquals"), (.restorable, "environmentEquals"):
                try validateStringDictionary(value, path: childPath)
            case (.state, "screenRegex"):
                try validateArray(value, kind: .regex, path: childPath, allowStrings: true)
            case (.state, "osc"), (.state, "oscSequences"):
                try validateArray(value, kind: .osc, path: childPath, allowStrings: true)
            case (.session, "sessionIdSource"),
                 (.session, "resumeCommand"),
                 (.session, "forkCommand"),
                 (.session, "cwd"),
                 (.session, "sessionDirectory"):
                try validateOptionalString(value, path: childPath)
            default: break
            }
        }
    }

    private static func validateStringArrayOrString(_ value: Any, path: String) throws {
        if let string = value as? String {
            try validateText(string, path: path)
            return
        }
        guard let values = value as? [Any] else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.stringOrArray",
                    defaultValue: "Must be a string or an array of strings"
                )
            )
        }
        for (index, value) in values.enumerated() {
            guard !(value is NSNull) else {
                throw CmuxAgentManifestValidationError(
                    path: "\(path)[\(index)]",
                    reason: localizedReason(
                        "agentManifest.validation.notNull",
                        defaultValue: "Must not be null"
                    )
                )
            }
            guard let string = value as? String else {
                throw CmuxAgentManifestValidationError(
                    path: "\(path)[\(index)]",
                    reason: localizedReason(
                        "agentManifest.validation.mustBeString",
                        defaultValue: "Must be a string"
                    )
                )
            }
            try validateText(string, path: "\(path)[\(index)]")
        }
    }

    private static func validateStringDictionary(_ value: Any, path: String) throws {
        guard let dictionary = value as? [String: Any] else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.stringObject",
                    defaultValue: "Must be an object of string values"
                )
            )
        }
        for (key, value) in dictionary {
            try validateText(key, path: "\(path).<key>")
            guard let string = value as? String else {
                throw CmuxAgentManifestValidationError(
                    path: "\(path).\(key)",
                    reason: localizedReason(
                        "agentManifest.validation.mustBeString",
                        defaultValue: "Must be a string"
                    )
                )
            }
            try validateText(string, path: "\(path).\(key)")
        }
    }

    private static func validateOptionalString(_ value: Any, path: String) throws {
        if value is NSNull { return }
        guard let string = value as? String else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.mustBeString",
                    defaultValue: "Must be a string"
                )
            )
        }
        try validateText(string, path: path)
    }

    static func codingPath(for error: DecodingError) -> String {
        let path: [any CodingKey]
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .dataCorrupted(context):
            path = context.codingPath
        case let .keyNotFound(key, context):
            path = context.codingPath + [key]
        @unknown default:
            path = []
        }
        return path.enumerated().map { offset, key in
            if let index = key.intValue { return "[\(index)]" }
            return offset == 0 ? key.stringValue : ".\(key.stringValue)"
        }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func decodingReason(for error: DecodingError) -> String {
        switch error {
        case .typeMismatch:
            return localizedReason(
                "agentManifest.validation.wrongType",
                defaultValue: "Value has the wrong type"
            )
        case .valueNotFound:
            return localizedReason(
                "agentManifest.validation.valueMissing",
                defaultValue: "Required value is missing"
            )
        case let .keyNotFound(key, _):
            return localizedReason(
                "agentManifest.validation.fieldMissing",
                defaultValue: "Required field '%@' is missing",
                arguments: [key.stringValue]
            )
        case let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return localizedReason(
                "agentManifest.validation.invalidValue",
                defaultValue: "Invalid value"
            )
        }
    }

    private static func validateArray(
        _ value: Any,
        kind: ObjectKind,
        path: String,
        allowStrings: Bool = false
    ) throws {
        guard let values = value as? [Any] else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.mustBeArray",
                    defaultValue: "Must be an array"
                )
            )
        }
        for (index, value) in values.enumerated() {
            let itemPath = "\(path)[\(index)]"
            if allowStrings, value is String { continue }
            try validateKeys(in: value, kind: kind, path: itemPath)
        }
    }
}
