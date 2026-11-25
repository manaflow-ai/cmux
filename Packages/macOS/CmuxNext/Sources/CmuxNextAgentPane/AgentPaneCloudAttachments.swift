public import CmuxNextSettings
public import Foundation
import CmuxNextCompat

/// First-send attachments: page-owned bytes, and link chips naming a file this app itself handed
/// the page or saved. A Send gesture never authorizes reading a path supplied by page script on
/// this Mac: a link chip is carried only when its path is one of `files`, the pane's record of
/// the person's own drop, paste or pick and of this app's Chat Uploads
/// (``AgentPaneModel/cloudCarriedFiles(_:)``). A folder the person dropped or picked goes whole
/// (its chip's name ends in a slash), by the upload CLI's folder rules. Image previews go as
/// images, with a copy on the machine as their file link; a carried file or folder goes as itself, by path.
public nonisolated struct AgentPaneCloudAttachments: Sendable {
    private let items: [JSONValue]
    /// Per item, the Mac file a carried link chip names, else nil.
    private let files: [String?]
    /// The carried files to clone into the paste folder before the upload (Chat Uploads, which the CLI never reads).
    private let staged: Set<String>

    /// The refusal's words when `items` can't go to Cloud: a chip this pane didn't hand the page.
    public static func refusal(_ items: [JSONValue]) -> String {
        "This attachment needs a local file. Run this chat on This Mac, or paste an image or text to send it to Cloud."
    }

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

    /// Nil for a path-only attachment whose path is not one of `carried`, or a malformed chip; no
    /// native file is opened.
    public init?(_ items: [JSONValue], files carried: Set<String> = [], staged: Set<String> = []) {
        var files: [String?] = []
        for item in items {
            guard let id = item["id"]?.stringValue, !id.isEmpty, let kind = item["kind"]?.stringValue,
                  let name = item["name"]?.stringValue,
                  // A folder's link chip names it with a trailing slash.
                  AgentPaneUpload.isFileName(kind == "link" && name.hasSuffix("/") ? String(name.dropLast()) : name) else { return nil }
            var file: String?
            switch kind {
            case "image", "document", "audio":
                guard let bytes = item["data"]?.stringValue, !bytes.isEmpty else { return nil }
            case "text", "pasted":
                guard item["text"]?.stringValue != nil else { return nil }
            case "link":
                guard let path = item["path"]?.stringValue, carried.contains(path) else { return nil }
                file = path
            default: return nil
            }
            files.append(file)
        }
        self.items = items
        self.files = files
        self.staged = staged.intersection(carried)
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
        for (item, file) in zip(items, files) {
            guard var chip = item.objectValue else { return nil }
            chip.removeValue(forKey: "path")
            chip.removeValue(forKey: "originalPath")
            chip.removeValue(forKey: "originalName")
            if file != nil {
                // A carried file or folder: a saved link to its copy on the machine, as a follow-up's upload makes.
                guard next < paths.count, paths[next].hasPrefix("/") else { return nil }
                chip["path"] = .string(paths[next])
                chip["saved"] = .bool(true)
                next += 1
            } else if chip["kind"]?.stringValue == "image" {
                guard next < paths.count, paths[next].hasPrefix("/") else { return nil }
                chip["originalPath"] = .string(paths[next])
                chip["originalName"] = chip["name"]
                next += 1
            }
            result.append(.object(chip))
        }
        return next == paths.count ? result : nil
    }

    /// Writes page-owned bytes privately, transfers them and the carried files (each by its own
    /// path, never read into memory, so a file of any size goes), then opens the chat with remote
    /// paths. The original chips stay with the send, so a machine repick can transfer them again.
    @MainActor public func withUploaded<Result>(in pastes: URL,
                                               upload: @MainActor ([String]) async throws -> Delivery,
                                               open: @MainActor ([JSONValue]) async throws -> Result) async throws -> Result {
        let images = try await uploads()
        if images.isEmpty, !files.contains(where: { $0 != nil }) {
            guard let chips = remapped([]) else { throw CocoaError(.fileReadCorruptFile) }
            return try await open(chips)
        }
        let folder = pastes.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: folder) } }
        let ordered = zip(items, files).compactMap { item, file in file ?? (item["kind"]?.stringValue == "image" ? "" : nil) }
        let paths = try await Task.detached(priority: .userInitiated) { [staged] in
            let written = images.isEmpty ? [] : try Self.write(images, in: folder)
            // In chip order, as ``remapped(_:)`` reads the answer; "" is the next image copy.
            var copies = written.makeIterator()
            return try ordered.enumerated().map { index, path in
                if path.isEmpty { return copies.next() ?? "" }
                return staged.contains(path) ? try Self.clone(path, in: folder, index: index) : path
            }
        }.value
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

    /// `path` cloned (APFS: no bytes copied; else a streamed copy, never held in memory) owner-only
    /// into its own folder `staged-<index>` of `folder`.
    static func clone(_ path: String, in folder: URL, index: Int) throws -> String {
        let manager = FileManager.checked, owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: owner)
        if !manager.fileExists(atPath: folder.path) { try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: owner) }
        let parent = folder.appendingPathComponent("staged-\(index)", isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: owner)
        let url = parent.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent, isDirectory: false)
        // The file a link names, never the link itself (a relative one would dangle in the copy).
        try manager.copyItem(at: URL(fileURLWithPath: path).resolvingSymlinksInPath(), to: url)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
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
