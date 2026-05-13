import Foundation

enum CmuxSettingsJSONWriter {
    static func write(
        _ changes: [(jsonPath: String, value: Any)],
        to path: String,
        fileManager: FileManager
    ) throws {
        let fileURL = URL(fileURLWithPath: path)
        guard let data = fileManager.contents(atPath: path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        let securityAttributes = existingSecurityAttributes(at: path, fileManager: fileManager)
        let sourceText = try JSONCParser.sourceText(from: data)
        let replacements = try changes.map { change in
            (
                jsonPath: change.jsonPath,
                literal: try JSONCValueEditor.literal(for: change.value)
            )
        }
        let editedText = try JSONCValueEditor.settingValues(replacements, in: sourceText.text)
        guard let output = editedText.data(using: sourceText.encoding) else {
            throw JSONCValueEditor.EditError.malformedJSONC("failed to encode edited settings file")
        }
        try output.write(to: fileURL, options: [.atomic])
        try restoreSecurityAttributes(securityAttributes, to: path, fileManager: fileManager)
    }

    private static func existingSecurityAttributes(
        at path: String,
        fileManager: FileManager
    ) -> [FileAttributeKey: Any]? {
        guard let existing = try? fileManager.attributesOfItem(atPath: path) else {
            return nil
        }
        let keys: [FileAttributeKey] = [.posixPermissions, .ownerAccountID, .groupOwnerAccountID]
        let attributes = keys.reduce(into: [FileAttributeKey: Any]()) { result, key in
            if let value = existing[key] {
                result[key] = value
            }
        }
        return attributes.isEmpty ? nil : attributes
    }

    private static func restoreSecurityAttributes(
        _ attributes: [FileAttributeKey: Any]?,
        to path: String,
        fileManager: FileManager
    ) throws {
        guard let attributes else {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return
        }
        var ownershipAttributes: [FileAttributeKey: Any] = [:]
        ownershipAttributes[.ownerAccountID] = attributes[.ownerAccountID]
        ownershipAttributes[.groupOwnerAccountID] = attributes[.groupOwnerAccountID]
        if !ownershipAttributes.isEmpty {
            try? fileManager.setAttributes(ownershipAttributes, ofItemAtPath: path)
        }
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }
}
