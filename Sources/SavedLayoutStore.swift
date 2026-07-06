import Foundation
import CmuxSettings

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

    let fileURL: URL

    private let fileManager: FileManager
    private var cachedFile: LayoutsFile?
    private var cachedModificationDate: Date?
    private var corruptFileDescription: String?

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
        let modificationDate = self.modificationDate()
        if let corruptFileDescription, cachedModificationDate == modificationDate {
            throw SavedLayoutStoreError.corruptFile(corruptFileDescription)
        }

        if let cachedFile, cachedModificationDate == modificationDate {
            return cachedFile
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty = LayoutsFile(layouts: [])
            cachedFile = empty
            cachedModificationDate = nil
            corruptFileDescription = nil
            return empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(LayoutsFile.self, from: data)
            cachedFile = decoded
            cachedModificationDate = modificationDate
            corruptFileDescription = nil
            return decoded
        } catch {
            let description = error.localizedDescription
            corruptFileDescription = description
            cachedModificationDate = modificationDate
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

        cachedFile = file
        cachedModificationDate = modificationDate()
    }

    private func modificationDate() -> Date? {
        (try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }
}
