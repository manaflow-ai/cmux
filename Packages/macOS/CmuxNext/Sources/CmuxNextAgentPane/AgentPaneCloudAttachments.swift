public import CmuxNextSettings
public import Foundation
import CmuxNextCompat

/// First-send attachments whose contents the composer already holds. This carries page-owned
/// bytes only: a Send gesture never authorizes reading a path supplied by page script on this Mac.
/// Path-only files and folders still need the native pick's exact-file authorization before they
/// can be carried. Image previews go as images, with a copy on the machine as their file link.
public nonisolated struct AgentPaneCloudAttachments: Sendable {
    private let items: [JSONValue]

    /// The temporary root the upload CLI resolves from this app's environment.
    public static var pastes: URL? {
        guard let temporary = ProcessInfo.processInfo.environment["TMPDIR"], temporary.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: temporary, isDirectory: true).appendingPathComponent("cmux-pastes", isDirectory: true)
    }

    /// A successful upload and the exact transfer's rollback if opening the chat fails.
    public struct Delivery {
        public var paths: [String]
        public var undo: @MainActor () async -> Void

        public init(paths: [String], undo: @escaping @MainActor () async -> Void) {
            self.paths = paths
            self.undo = undo
        }
    }

    /// Nil for a path-only attachment or a malformed chip; no native file is opened.
    public init?(_ items: [JSONValue]) {
        for item in items {
            guard let id = item["id"]?.stringValue, !id.isEmpty,
                  let name = item["name"]?.stringValue, AgentPaneUpload.isFileName(name),
                  let kind = item["kind"]?.stringValue else { return nil }
            switch kind {
            case "image", "document", "audio":
                guard let bytes = item["data"]?.stringValue, !bytes.isEmpty else { return nil }
            case "text", "pasted":
                guard item["text"]?.stringValue != nil else { return nil }
            default: return nil
            }
        }
        self.items = items
    }

    /// Copies image previews off the main actor for their file links. Other media go inline only.
    @concurrent public func uploads() async throws -> [AgentPaneUpload] {
        try items.compactMap { item in
            guard item["kind"]?.stringValue == "image", let encoded = item["data"]?.stringValue else { return nil }
            guard let data = Data(base64Encoded: encoded), let name = item["name"]?.stringValue else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return AgentPaneUpload(name: name, data: data)
        }
    }

    /// The same chips and inline ids, with references to this Mac removed. The paths must be the
    /// upload owner's answer in file order. Never forwards a page's `path` or `originalPath`.
    public func remapped(_ paths: [String]) -> [JSONValue]? {
        var next = 0
        var result: [JSONValue] = []
        for item in items {
            guard var chip = item.objectValue else { return nil }
            chip.removeValue(forKey: "path")
            chip.removeValue(forKey: "originalPath")
            chip.removeValue(forKey: "originalName")
            if chip["kind"]?.stringValue == "image" {
                guard next < paths.count, paths[next].hasPrefix("/") else { return nil }
                chip["originalPath"] = .string(paths[next])
                chip["originalName"] = chip["name"]
                next += 1
            }
            result.append(.object(chip))
        }
        return next == paths.count ? result : nil
    }

    /// Writes page-owned bytes privately, transfers them, then opens the chat with remote paths.
    /// The original chips stay with the send, so a machine repick can transfer them again.
    @MainActor public func withUploaded<Result>(in pastes: URL,
                                               upload: @MainActor ([String]) async throws -> Delivery,
                                               open: @MainActor ([JSONValue]) async throws -> Result) async throws -> Result {
        let files = try await uploads()
        if files.isEmpty {
            guard let chips = remapped([]) else { throw CocoaError(.fileReadCorruptFile) }
            return try await open(chips)
        }
        let folder = pastes.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: folder) } }
        let paths = try await Task.detached(priority: .userInitiated) { try Self.write(files, in: folder) }.value
        try Task.checkCancellation()
        let delivery = try await upload(paths)
        do {
            try Task.checkCancellation()
            guard let chips = remapped(delivery.paths) else { throw CocoaError(.fileReadCorruptFile) }
            return try await open(chips)
        } catch {
            await delivery.undo()
            throw error
        }
    }

    /// Each file owner-only in its own folder, so two files may share a name. Shared with the
    /// already-running Cloud chat uploader; no native path from the page is read here.
    public static func write(_ files: [AgentPaneUpload], in folder: URL) throws -> [String] {
        let manager = FileManager.checked, owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: owner)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: owner)
        return try files.enumerated().map { index, file in
            let parent = folder.appendingPathComponent(String(index), isDirectory: true)
            try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: owner)
            let url = parent.appendingPathComponent(file.name, isDirectory: false)
            guard manager.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return url.path
        }
    }
}
