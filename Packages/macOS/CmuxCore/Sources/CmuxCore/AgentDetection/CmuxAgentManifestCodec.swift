public import Foundation

/// Strict JSON decoder and validator for agent manifests.
public struct CmuxAgentManifestCodec: Sendable {
    private init() {}
    /// Maximum encoded size accepted for one manifest file.
    public static let maximumManifestBytes = 512 * 1024
    /// Maximum newest terminal screen/OSC bytes evaluated by the engine.
    /// A 128 KiB window exceeds a very large visible terminal while bounding
    /// every literal and regular-expression scan.
    public static let maximumScreenInputBytes = 128 * 1024
    /// Maximum number of manifests in one catalog tier.
    public static let maximumManifestCount = 256
    /// Maximum number of ordered state rules in one manifest.
    public static let maximumStateRuleCount = 128
    /// Maximum number of process matcher alternatives.
    public static let maximumProcessMatcherCount = 64
    /// Maximum number of predicates/conditions in one rule.
    public static let maximumConditionCount = 256
    /// Maximum number of environment entries in an admission condition.
    public static let maximumEnvironmentEntryCount = 128
    /// Maximum UTF-8 length of a text field.
    public static let maximumStringLength = 16 * 1024
    /// Maximum UTF-8 length of one regular-expression source.
    public static let maximumRegexLength = 8 * 1024

    /// Decodes one complete manifest and rejects unknown keys before Codable
    /// runs (Swift's synthesized Codable otherwise ignores unknown keys).
    ///
    /// - Parameter data: UTF-8 JSON data for one complete manifest.
    /// - Returns: The decoded and strictly validated manifest.
    /// - Throws: ``CmuxAgentManifestValidationError`` for malformed JSON,
    ///   unknown keys, invalid values, or exceeded resource limits.
    public static func decode(data: Data) throws -> CmuxAgentDetectionManifest {
        guard data.count <= maximumManifestBytes else {
            throw CmuxAgentManifestValidationError(
                path: "",
                reason: localizedReason(
                    "agentManifest.validation.manifestTooLarge",
                    defaultValue: "Manifest exceeds 512 KiB"
                )
            )
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CmuxAgentManifestValidationError(
                path: "",
                reason: localizedReason(
                    "agentManifest.validation.invalidJSON",
                    defaultValue: "Invalid JSON: %@",
                    arguments: [error.localizedDescription]
                )
            )
        }
        guard object is [String: Any] else {
            throw CmuxAgentManifestValidationError(
                path: "",
                reason: localizedReason(
                    "agentManifest.validation.manifestObject",
                    defaultValue: "Manifest must be a JSON object"
                )
            )
        }
        try validateKeys(in: object, kind: .manifest, path: "")
        do {
            let manifest = try JSONDecoder().decode(CmuxAgentDetectionManifest.self, from: data)
            try validate(manifest)
            return manifest
        } catch let error as CmuxAgentManifestValidationError {
            throw error
        } catch let error as DecodingError {
            throw CmuxAgentManifestValidationError(
                path: Self.codingPath(for: error),
                reason: Self.decodingReason(for: error)
            )
        } catch {
            throw CmuxAgentManifestValidationError(
                path: "",
                reason: localizedReason(
                    "agentManifest.validation.cannotDecodeManifest",
                    defaultValue: "Cannot decode manifest: %@",
                    arguments: [error.localizedDescription]
                )
            )
        }
    }

    /// Validates a value that has already been decoded. This is public so a
    /// caller constructing a manifest programmatically gets the same guards as
    /// a file-backed manifest.
    ///
    /// - Parameter manifest: The complete manifest value to validate.
    /// - Throws: ``CmuxAgentManifestValidationError`` when any schema or
    ///   resource-limit invariant is violated.
    public static func validate(_ manifest: CmuxAgentDetectionManifest) throws {
        guard manifest.schemaVersion == CmuxAgentDetectionManifest.currentSchemaVersion else {
            throw CmuxAgentManifestValidationError(
                path: "schemaVersion",
                reason: localizedReason(
                    "agentManifest.validation.unsupportedSchemaVersion",
                    defaultValue: "Unsupported schema version %1$lld; expected %2$lld",
                    arguments: [manifest.schemaVersion, CmuxAgentDetectionManifest.currentSchemaVersion]
                )
            )
        }
        try validateID(manifest.id, path: "id")
        try validateText(manifest.displayName, path: "displayName")
        if let icon = manifest.iconAssetName {
            try validateText(icon, path: "iconAssetName")
        }
        guard !manifest.process.matchers.isEmpty else {
            throw CmuxAgentManifestValidationError(
                path: "process.matchers",
                reason: localizedReason(
                    "agentManifest.validation.matcherRequired",
                    defaultValue: "At least one process matcher is required"
                )
            )
        }
        guard manifest.process.matchers.count <= maximumProcessMatcherCount else {
            throw CmuxAgentManifestValidationError(
                path: "process.matchers",
                reason: localizedReason(
                    "agentManifest.validation.tooManyMatchers",
                    defaultValue: "Too many process matchers"
                )
            )
        }
        var matcherIDs = Set<String>()
        for (index, matcher) in manifest.process.matchers.enumerated() {
            let path = "process.matchers[\(index)]"
            try validateID(matcher.id, path: "\(path).id", allowEmpty: false)
            guard matcherIDs.insert(matcher.id).inserted else {
                throw CmuxAgentManifestValidationError(
                    path: "\(path).id",
                    reason: localizedReason(
                        "agentManifest.validation.duplicateMatcherID",
                        defaultValue: "Duplicate process matcher id '%@'",
                        arguments: [matcher.id]
                    )
                )
            }
            guard !matcher.processNames.isEmpty
                || !matcher.processPathContains.isEmpty
                || !matcher.processPathRegex.isEmpty
                || !matcher.argvContainsAll.isEmpty
                || !matcher.argvContainsAny.isEmpty
                || !matcher.argvBasenamesAny.isEmpty
                || !matcher.environmentEquals.isEmpty else {
                throw CmuxAgentManifestValidationError(
                    path: path,
                    reason: localizedReason(
                        "agentManifest.validation.matcherNoCriteria",
                        defaultValue: "Matcher has no criteria"
                    )
                )
            }
            let predicateCount = matcher.processNames.count
                + matcher.processPathContains.count
                + matcher.processPathRegex.count
                + matcher.argvContainsAll.count
                + matcher.argvContainsAny.count
                + matcher.argvBasenamesAny.count
                + matcher.environmentEquals.count
            guard predicateCount <= maximumConditionCount else {
                throw CmuxAgentManifestValidationError(
                    path: path,
                    reason: localizedReason(
                        "agentManifest.validation.tooManyPredicates",
                        defaultValue: "Matcher has too many predicates (maximum %lld)",
                        arguments: [maximumConditionCount]
                    )
                )
            }
            guard matcher.environmentEquals.count <= maximumEnvironmentEntryCount else {
                throw CmuxAgentManifestValidationError(
                    path: "\(path).environmentEquals",
                    reason: localizedReason(
                        "agentManifest.validation.tooManyEnvironmentEntries",
                        defaultValue: "Too many environment entries (maximum %lld)",
                        arguments: [maximumEnvironmentEntryCount]
                    )
                )
            }
            try validateStrings(matcher.processNames, path: "\(path).processNames")
            try validateStrings(matcher.processPathContains, path: "\(path).processPathContains")
            for (regexIndex, regex) in matcher.processPathRegex.enumerated() {
                try validateRegex(
                    regex,
                    path: "\(path).processPathRegex[\(regexIndex)].pattern"
                )
            }
            try validateStrings(matcher.argvContainsAll, path: "\(path).argvContainsAll")
            try validateStrings(matcher.argvContainsAny, path: "\(path).argvContainsAny")
            try validateStrings(matcher.argvBasenamesAny, path: "\(path).argvBasenamesAny")
            for (key, value) in matcher.environmentEquals {
                try validateText(key, path: "\(path).environmentEquals.<key>")
                try validateText(value, path: "\(path).environmentEquals.\(key)")
            }
        }

        guard manifest.states.count <= maximumStateRuleCount else {
            throw CmuxAgentManifestValidationError(
                path: "states",
                reason: localizedReason(
                    "agentManifest.validation.tooManyStateRules",
                    defaultValue: "Too many state rules"
                )
            )
        }
        var stateIDs = Set<String>()
        for (index, rule) in manifest.states.enumerated() {
            let path = "states[\(index)]"
            try validateID(rule.id, path: "\(path).id", allowEmpty: false)
            guard stateIDs.insert(rule.id).inserted else {
                throw CmuxAgentManifestValidationError(
                    path: "\(path).id",
                    reason: localizedReason(
                        "agentManifest.validation.duplicateStateRuleID",
                        defaultValue: "Duplicate state rule id '%@'",
                        arguments: [rule.id]
                    )
                )
            }
            try validateStrings(rule.screenContains, path: "\(path).screenContains")
            guard rule.screenContains.count + rule.screenRegex.count + rule.osc.count <= maximumConditionCount else {
                throw CmuxAgentManifestValidationError(
                    path: path,
                    reason: localizedReason(
                        "agentManifest.validation.tooManyStateConditions",
                        defaultValue: "State rule has too many conditions (maximum %lld)",
                        arguments: [maximumConditionCount]
                    )
                )
            }
            for (regexIndex, regex) in rule.screenRegex.enumerated() {
                try validateRegex(
                    regex,
                    path: "\(path).screenRegex[\(regexIndex)].pattern"
                )
            }
            for (oscIndex, osc) in rule.osc.enumerated() {
                let oscPath = "\(path).osc[\(oscIndex)].sequence"
                try validateOSCSequence(osc.sequence, path: oscPath)
            }
            guard !rule.screenContains.isEmpty || !rule.screenRegex.isEmpty || !rule.osc.isEmpty else {
                throw CmuxAgentManifestValidationError(
                    path: path,
                    reason: localizedReason(
                        "agentManifest.validation.stateRuleNoConditions",
                        defaultValue: "State rule has no screen or OSC conditions"
                    )
                )
            }
        }

        if let session = manifest.session {
            // A present session object is an opt-in to persistence. Requiring
            // both identity and resume templates prevents a newly added
            // detection-only agent from silently inheriting the bridge's
            // compatibility defaults and appearing restorable.
            guard session.supportsRestoration else {
                throw CmuxAgentManifestValidationError(
                    path: "session",
                    reason: localizedReason(
                        "agentManifest.validation.sessionContract",
                        defaultValue: "sessionIdSource and resumeCommand are required; omit session for detection-only agents"
                    )
                )
            }
            if let source = session.sessionIdSource {
                try validateSessionIDSource(source, path: "session.sessionIdSource")
            }
            if let resume = session.resumeCommand {
                try validateCommand(resume, path: "session.resumeCommand")
            }
            if let fork = session.forkCommand { try validateCommand(fork, path: "session.forkCommand") }
            if let cwd = session.cwd {
                try validateText(cwd, path: "session.cwd")
                guard ["preserve", "ignore", "none"].contains(cwd.lowercased()) else {
                    throw CmuxAgentManifestValidationError(
                        path: "session.cwd",
                        reason: localizedReason(
                            "agentManifest.validation.cwdPolicy",
                            defaultValue: "Must be 'preserve', 'ignore', or 'none' (an alias for 'ignore')"
                        )
                    )
                }
            }
            if let directory = session.sessionDirectory { try validateText(directory, path: "session.sessionDirectory") }
        }
        if let condition = manifest.restorableWhen {
            guard manifest.session?.supportsRestoration == true else {
                throw CmuxAgentManifestValidationError(
                    path: "restorableWhen",
                    reason: localizedReason(
                        "agentManifest.validation.requiresSessionContract",
                        defaultValue: "Requires a session restoration contract"
                    )
                )
            }
            guard condition.environmentEquals.count <= maximumEnvironmentEntryCount else {
                throw CmuxAgentManifestValidationError(
                    path: "restorableWhen.environmentEquals",
                    reason: localizedReason(
                        "agentManifest.validation.tooManyEnvironmentEntries",
                        defaultValue: "Too many environment entries (maximum %lld)",
                        arguments: [maximumEnvironmentEntryCount]
                    )
                )
            }
            for (key, value) in condition.environmentEquals {
                try validateText(key, path: "restorableWhen.environmentEquals.<key>")
                try validateText(value, path: "restorableWhen.environmentEquals.\(key)")
            }
        }
    }

    private static func validateID(_ value: String, path: String, allowEmpty: Bool = false) throws {
        if allowEmpty && value.isEmpty { return }
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.invalidID",
                    defaultValue: "Must start with a letter or number and contain only letters, numbers, dots, underscores, and hyphens"
                )
            )
        }
        try validateText(value, path: path)
    }

    static func validateText(_ value: String, path: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.notBlank",
                    defaultValue: "Must not be blank"
                )
            )
        }
        guard value.utf8.count <= maximumStringLength else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.valueTooLong",
                    defaultValue: "Value is too long"
                )
            )
        }
    }

    private static func validateStrings(_ values: [String], path: String) throws {
        for (index, value) in values.enumerated() {
            try validateText(value, path: "\(path)[\(index)]")
        }
    }

    private static func validateCommand(_ value: String, path: String) throws {
        try validateText(value, path: path)
        guard value.contains("{{sessionId}}") || value.contains("{{sessionPath}}") else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.commandPlaceholder",
                    defaultValue: "Must include {{sessionId}} or {{sessionPath}}"
                )
            )
        }
    }

    private static func validateSessionIDSource(_ value: String, path: String) throws {
        try validateText(value, path: path)
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = [
            "pisessionfile", "pi-session-file",
            "grokSessionDirectory".lowercased(), "grok-session-directory",
            "hermesstatedb", "hermes-state-db", "statedb", "state-db",
        ]
        guard value.hasPrefix("-") || known.contains(normalized) else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.sessionSource",
                    defaultValue: "Must be a supported session source name or an argv option beginning with '-'"
                )
            )
        }
    }

    private static func validateOSCSequence(_ value: String, path: String) throws {
        guard !value.isEmpty else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.oscBlank",
                    defaultValue: "OSC sequence must not be blank"
                )
            )
        }
        guard value.utf8.count <= maximumStringLength else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.oscTooLong",
                    defaultValue: "OSC sequence is too long"
                )
            )
        }
        let scalars = Array(value.unicodeScalars)
        let hasEscapedIntroducer = scalars.count >= 2
            && scalars[0].value == 0x1B
            && scalars[1].value == 0x5D
        let hasC1Introducer = scalars.first?.value == 0x9D
        guard hasEscapedIntroducer || hasC1Introducer else {
            throw CmuxAgentManifestValidationError(
                path: path,
                reason: localizedReason(
                    "agentManifest.validation.oscIntroducer",
                    defaultValue: "Must begin with ESC ] or the C1 OSC byte (write ESC ] in JSON as \\u001b])"
                )
            )
        }
    }

}
