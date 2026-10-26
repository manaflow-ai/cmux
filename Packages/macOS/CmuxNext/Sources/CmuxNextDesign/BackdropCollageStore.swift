public import Foundation
import CmuxNextCompat
import ImageIO
import UniformTypeIdentifiers

/// Persists independent collage records and PNG drawings in an injected directory.
///
/// A save always returns a fresh id. It never deletes an earlier edit; the eventual caller must
/// switch references and establish that an old id is unused before explicitly deleting it.
public actor BackdropCollageStore {
    private let folder: URL
    private let fileManager: FileManager

    /// Creates a store without reading or writing the directory.
    public init(folder: URL, fileManager: FileManager = .default) {
        self.folder = folder.standardizedFileURL
        self.fileManager = fileManager
    }

    /// Draws and saves a new JSON/PNG pair using only the supplied authorized sources.
    ///
    /// A failed save removes its own partial files. The PNG is published last, so a listed
    /// drawing always has its record. No existing collage is replaced or removed.
    public func save(_ collage: BackdropCollage, sources: [String: URL]) throws -> String {
        assertBlockingAllowed(.fileIO)
        let image = try BackdropCollageRenderer(sources: sources).render(collage)
        let record = try JSONEncoder().encode(collage)
        let id = "c-" + UUID().uuidString.lowercased()
        let png = try imageURL(id), json = try recordURL(id)
        let partial = folder.appendingPathComponent(".\(id).partial")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: partial) }
        do {
            guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw BackdropCollage.Failure.renderingFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw BackdropCollage.Failure.renderingFailed }
            try record.blockingWrite(to: json, options: .atomic)
            try fileManager.moveItem(at: partial, to: png)
        } catch {
            try? fileManager.removeItem(at: json)
            throw error
        }
        return id
    }

    /// Reads a complete, valid record; incomplete pairs and symbolic links are refused.
    public func load(_ id: String) throws -> BackdropCollage {
        assertBlockingAllowed(.fileIO)
        let json = try recordURL(id), png = try imageURL(id)
        guard isPlainFile(json), isPlainFile(png) else { throw BackdropCollage.Failure.invalid }
        let collage = try JSONDecoder().decode(BackdropCollage.self, from: Data(blockingContentsOf: json))
        try collage.validate()
        return collage
    }

    /// Lists complete, valid records in stable id order, ignoring partial or corrupt records.
    public func list() throws -> [String] {
        assertBlockingAllowed(.fileIO)
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            return (try? load(id)) == nil ? nil : id
        }.sorted()
    }

    /// Returns the drawing path for a safe id without reading the filesystem.
    public func imageURL(_ id: String) throws -> URL {
        guard Self.isValidID(id) else { throw BackdropCollage.Failure.invalid }
        return folder.appendingPathComponent(id + ".png")
    }

    /// Removes only this id's files. The caller must establish that no surface still references it.
    public func delete(_ id: String) throws {
        assertBlockingAllowed(.fileIO)
        let png = try imageURL(id), json = try recordURL(id)
        try fileManager.removeItem(at: png)
        try fileManager.removeItem(at: json)
    }

    private func recordURL(_ id: String) throws -> URL {
        guard Self.isValidID(id) else { throw BackdropCollage.Failure.invalid }
        return folder.appendingPathComponent(id + ".json")
    }

    private func isPlainFile(_ url: URL) -> Bool {
        let values = try? url.blockingResourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private nonisolated static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
