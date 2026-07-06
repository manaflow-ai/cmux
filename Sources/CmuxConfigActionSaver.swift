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
    /// action was saved under: slugged from `title` and uniquified against both
    /// the file's action ids and `reservedActionIDs` (the caller passes the
    /// active store's resolved ids so project-local actions can't shadow the
    /// saved one).
    @discardableResult
    static func saveWorkspaceAction(
        title: String,
        definition: CmuxWorkspaceDefinition,
        globalConfigPath: String,
        reservedActionIDs: Set<String> = [],
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

        if fileManager.fileExists(atPath: globalConfigPath) {
            try validateEditableConfig(source, globalConfigPath: globalConfigPath)
        }

        let actionID = uniqueActionID(
            forTitle: title,
            existingIDs: existingActionIDs(inConfigSource: source)
                .union(reservedActionIDs)
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

        try writeOwnerOnlyConfig(updated, globalConfigPath: globalConfigPath, fileManager: fileManager)
        return SaveResult(actionID: actionID, configPath: globalConfigPath)
    }

    /// Removes `actions.<actionID>` from the config file, preserving comments
    /// and formatting. Only global-config actions are deletable this way.
    static func deleteAction(
        id actionID: String,
        globalConfigPath: String,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: globalConfigPath),
              let data = fileManager.contents(atPath: globalConfigPath),
              let source = String(data: data, encoding: .utf8) else {
            throw SaveError.unreadableConfig(globalConfigPath)
        }
        try validateEditableConfig(source, globalConfigPath: globalConfigPath)
        guard let updated = JSONCObjectEditor.removeNestedObjectProperty(
            parentKey: "actions",
            childKey: actionID,
            in: source
        ) else {
            throw SaveError.malformedConfig(globalConfigPath)
        }
        try writeOwnerOnlyConfig(updated, globalConfigPath: globalConfigPath, fileManager: fileManager)
    }

    /// Fail closed before editing: a config that doesn't fully parse, or
    /// whose `actions` value isn't an object, must never be structurally
    /// edited — the JSONC editors could otherwise replace user-authored
    /// (broken) content.
    private static func validateEditableConfig(_ source: String, globalConfigPath: String) throws {
        guard let sanitized = try? JSONCParser.preprocess(data: Data(source.utf8)),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any] else {
            throw SaveError.malformedConfig(globalConfigPath)
        }
        if let existingActions = root["actions"], !(existingActions is [String: Any]) {
            throw SaveError.malformedConfig(globalConfigPath)
        }
    }

    /// Shared config writer: resolves dotfiles symlinks (an atomic write to
    /// the link path would replace the link with a regular file), creates a
    /// 0600 temp in the target directory, and rename(2)s it into place so the
    /// content — commands, URLs, env values — is owner-only from its very
    /// first byte, with no umask-permission window.
    private static func writeOwnerOnlyConfig(
        _ content: String,
        globalConfigPath: String,
        fileManager: FileManager
    ) throws {
        let configURL = URL(fileURLWithPath: globalConfigPath).resolvingSymlinksInPath()
        let directoryURL = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tempURL = directoryURL.appendingPathComponent(".cmux.json.tmp-\(UUID().uuidString)")
        guard fileManager.createFile(
            atPath: tempURL.path,
            contents: Data(content.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SaveError.unreadableConfig(globalConfigPath)
        }
        let renameResult = tempURL.path.withCString { tempPath in
            configURL.path.withCString { destinationPath in
                rename(tempPath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            try? fileManager.removeItem(at: tempURL)
            throw SaveError.unreadableConfig(globalConfigPath)
        }
        // Also heal pre-existing loose permissions on the target.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
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
