import Foundation
import CmuxSettings
import CmuxWorkspaces

struct CmuxSavedLayout: Codable, Sendable {
    var name: String
    var description: String?
    var workspace: CmuxWorkspaceDefinition
}

enum SavedLayoutStoreError: Error, Equatable {
    case blankName
    case duplicateName(String)
    case notFound(String)
    case corruptFile(String)
}

@MainActor
final class SavedLayoutStore {
    struct LayoutsFile: Codable, Sendable {
        var layouts: [CmuxSavedLayout]
    }

    private struct CachedLayoutsFile: Sendable {
        var modificationDate: Date?
        var file: LayoutsFile
    }

    let fileURL: URL

    private let fileManager: FileManager
    private var corruptFileDescription: String?
    private static var sharedCacheByPath: [String: CachedLayoutsFile] = [:]

    init(
        fileURL: URL = CmuxConfigLocation().userConfigFile
            .deletingLastPathComponent()
            .appendingPathComponent("layouts.json", isDirectory: false),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func list() throws -> [CmuxSavedLayout] {
        try load().layouts
    }

    func layout(named name: String) throws -> CmuxSavedLayout? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        return try load().layouts.first { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame }
    }

    func save(_ layout: CmuxSavedLayout, overwrite: Bool) throws {
        let normalizedName = layout.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SavedLayoutStoreError.blankName
        }

        var file = try load()
        let replacement = CmuxSavedLayout(
            name: normalizedName,
            description: layout.description,
            workspace: layout.workspace
        )
        if let index = file.layouts.firstIndex(where: { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame }) {
            guard overwrite else {
                throw SavedLayoutStoreError.duplicateName(normalizedName)
            }
            file.layouts[index] = replacement
        } else {
            file.layouts.append(replacement)
        }
        try write(file)
    }

    func delete(named name: String) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SavedLayoutStoreError.blankName
        }
        var file = try load()
        guard let index = file.layouts.firstIndex(where: { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame }) else {
            throw SavedLayoutStoreError.notFound(normalizedName)
        }
        file.layouts.remove(at: index)
        try write(file)
    }

    private func load() throws -> LayoutsFile {
        // Nonexistence always resets to the default empty state, including
        // after a corrupt file was deleted; check it before the corrupt
        // short-circuit so removal is a valid recovery path.
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty = LayoutsFile(layouts: [])
            Self.sharedCacheByPath[cacheKey] = CachedLayoutsFile(modificationDate: nil, file: empty)
            corruptFileDescription = nil
            return empty
        }

        let modificationDate = self.modificationDate()
        if let corruptFileDescription,
           Self.sharedCacheByPath[cacheKey]?.modificationDate == modificationDate {
            throw SavedLayoutStoreError.corruptFile(corruptFileDescription)
        }

        if let cached = Self.sharedCacheByPath[cacheKey],
           cached.modificationDate == modificationDate {
            return cached.file
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(LayoutsFile.self, from: data)
            Self.sharedCacheByPath[cacheKey] = CachedLayoutsFile(modificationDate: modificationDate, file: decoded)
            corruptFileDescription = nil
            return decoded
        } catch {
            let description = error.localizedDescription
            corruptFileDescription = description
            throw SavedLayoutStoreError.corruptFile(description)
        }
    }

    private func write(_ file: LayoutsFile) throws {
        if let corruptFileDescription {
            throw SavedLayoutStoreError.corruptFile(corruptFileDescription)
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        let temporaryURL = directoryURL.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }

        Self.sharedCacheByPath[cacheKey] = CachedLayoutsFile(modificationDate: modificationDate(), file: file)
        corruptFileDescription = nil
    }

    private func modificationDate() -> Date? {
        (try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    private var cacheKey: String {
        fileURL.standardizedFileURL.path
    }
}
