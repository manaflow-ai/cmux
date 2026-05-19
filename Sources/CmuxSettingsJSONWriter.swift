import Foundation
import os

nonisolated private let cmuxSettingsJSONWriterLog = Logger(subsystem: "com.cmuxterm.app", category: "SettingsFile")

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
        let temporaryURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try output.write(to: temporaryURL, options: [.atomic])
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL, backupItemName: nil, options: [])
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        restoreSecurityAttributes(securityAttributes, to: path, fileManager: fileManager)
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
    ) {
        guard let attributes else {
            setSecurityAttributesBestEffort([.posixPermissions: 0o600], to: path, fileManager: fileManager)
            return
        }
        var ownershipAttributes: [FileAttributeKey: Any] = [:]
        ownershipAttributes[.ownerAccountID] = attributes[.ownerAccountID]
        ownershipAttributes[.groupOwnerAccountID] = attributes[.groupOwnerAccountID]
        if !ownershipAttributes.isEmpty {
            setSecurityAttributesBestEffort(ownershipAttributes, to: path, fileManager: fileManager)
        }
        if let permissions = attributes[.posixPermissions] {
            setSecurityAttributesBestEffort([.posixPermissions: permissions], to: path, fileManager: fileManager)
        }
    }

    private static func setSecurityAttributesBestEffort(
        _ attributes: [FileAttributeKey: Any],
        to path: String,
        fileManager: FileManager
    ) {
        do {
            try fileManager.setAttributes(attributes, ofItemAtPath: path)
        } catch {
            cmuxSettingsJSONWriterLog.error("Failed to restore cmux.json attributes after write-back: \(String(describing: error), privacy: .private)")
        }
    }
}
