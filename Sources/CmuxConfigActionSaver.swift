import Foundation

/// Persists "Save Workspace as Action" results into the global cmux.json,
/// preserving JSONC comments and formatting via `JSONCObjectEditor`.
enum CmuxConfigActionSaver {

    struct SaveResult: Equatable {
        var actionID: String
        var configPath: String
    }

    enum SaveError: LocalizedError, Equatable {
        case unreadableConfig(String)
        case malformedConfig(String)

        var errorDescription: String? {
            switch self {
            case .unreadableConfig(let path):
                let format = String(
                    localized: "error.cmuxConfigActionSaver.unreadableConfig",
                    defaultValue: "Couldn't read %@."
                )
                return String(format: format, path)
            case .malformedConfig(let path):
                let format = String(
                    localized: "error.cmuxConfigActionSaver.malformedConfig",
                    defaultValue: "%@ isn't a valid JSON object, so the action couldn't be added. Fix the file and try again."
                )
                return String(format: format, path)
            }
        }
    }

    static let emptyConfigTemplate = """
    {
      "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json"
    }

    """

    /// Upserts `actions.<generated-id>` in the config file at `globalConfigPath`,
    /// creating the file from a minimal template when absent. Returns the id the
    /// action was saved under (slugged from `title`, uniquified against existing
    /// action ids).
    @discardableResult
    static func saveWorkspaceAction(
        title: String,
        definition: CmuxWorkspaceDefinition,
        globalConfigPath: String,
        fileManager: FileManager = .default
    ) throws -> SaveResult {
        let source: String
        if fileManager.fileExists(atPath: globalConfigPath) {
            guard let data = fileManager.contents(atPath: globalConfigPath),
                  let text = String(data: data, encoding: .utf8) else {
                throw SaveError.unreadableConfig(globalConfigPath)
            }
            source = text
        } else {
            source = emptyConfigTemplate
        }

        let actionID = uniqueActionID(
            forTitle: title,
            existingIDs: existingActionIDs(inConfigSource: source)
        )
        let actionDefinition = CmuxConfigActionDefinition(
            action: .workspace(definition, restart: nil),
            title: title
        )
        let valueJSON = try encodeActionValueJSON(actionDefinition)
        guard let updated = JSONCObjectEditor.setNestedObjectProperty(
            parentKey: "actions",
            childKey: actionID,
            childValueJSON: valueJSON,
            in: source
        ) else {
            throw SaveError.malformedConfig(globalConfigPath)
        }

        let configURL = URL(fileURLWithPath: globalConfigPath)
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
        return SaveResult(actionID: actionID, configPath: globalConfigPath)
    }

    static func encodeActionValueJSON(_ definition: CmuxConfigActionDefinition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(definition)
        return String(decoding: data, as: UTF8.self)
    }

    static func existingActionIDs(inConfigSource source: String) -> Set<String> {
        guard let sanitized = try? JSONCParser.preprocess(data: Data(source.utf8)),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
              let actions = root["actions"] as? [String: Any] else {
            return []
        }
        return Set(actions.keys)
    }

    static func uniqueActionID(forTitle title: String, existingIDs: Set<String>) -> String {
        let base = slug(forTitle: title)
        guard existingIDs.contains(base) else { return base }
        var suffix = 2
        while existingIDs.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    static func slug(forTitle title: String) -> String {
        let lowered = title.lowercased()
        var slug = ""
        var previousWasDash = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                slug.append("-")
                previousWasDash = true
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? "workspace" : slug
    }
}
