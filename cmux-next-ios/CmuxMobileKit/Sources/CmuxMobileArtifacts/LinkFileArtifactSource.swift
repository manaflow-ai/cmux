import CmuxMobileTransport
import Foundation

/// Reads artifacts from the Mac over the link's `file-preview` service (PROTOCOL.md):
/// one channel per file, opened with `{"path": <absolute path>}`, a size header then data frames
/// until the Mac closes it with `eof`. The Mac confines reads to workspace
/// roots and refuses folders, so folders and paths outside a root explain why.
/// A file of any size opens: its bytes go to a local copy in the temporary
/// folder as they arrive, and the preview reads that copy.
public struct LinkFileArtifactSource: ArtifactSource {
    /// The connected Mac's link, or nil while offline.
    let link: @Sendable () async -> (any MacLink)?
    /// Resolves relative references (the session's working directory).
    let baseDirectory: String?
    let macName: String
    /// Explicit account/Mac/resource identity supplied by the authenticated
    /// owner, never inferred from a display name or the file path.
    public let thumbnailCacheScope: String?
    private let availableCapacity: PreviewStorage.Capacity
    var fileStore: PreviewFileStore = .shared
    /// Largest text, image or PDF the preview decodes in memory; a larger one
    /// opens in Quick Look from its local copy (not a size cap).
    public static let inMemoryBytes: Int64 = 24 << 20

    public init(macName: String, baseDirectory: String?, thumbnailCacheScope: String? = nil,
                availableCapacity: (@Sendable (URL) throws -> Int64)? = nil,
                link: @escaping @Sendable () async -> (any MacLink)?) {
        self.link = link
        self.baseDirectory = baseDirectory
        self.macName = macName
        self.thumbnailCacheScope = thumbnailCacheScope
        self.availableCapacity = availableCapacity ?? PreviewStorage.availableCapacity
    }

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        switch artifact.kind {
        case .link:
            guard let url = URL(string: artifact.reference) else { throw ArtifactNotFound(reference: artifact.reference) }
            return .web(url)
        case .directory:
            throw ArtifactUnavailable("Open a file inside this folder.")
        default:
            break
        }
        guard let path = Self.absolutePath(artifact.reference, base: baseDirectory) else {
            throw ArtifactUnavailable("\(artifact.reference) isn't inside a known folder on \(macName).")
        }
        guard let link = await link() else {
            throw ArtifactUnavailable("Connect to \(macName) to open \(artifact.name).")
        }
        let file = try await Self.read(path: path, over: link, macName: macName, for: artifact,
                                       capacity: availableCapacity, store: fileStore)
        return try Self.content(for: artifact, file: file)
    }

    /// Absolute path for a reference: absolute stays, `./x` and `x/y` join the base; `~` can't be resolved here.
    public static func absolutePath(_ reference: String, base: String?) -> String? {
        if reference.hasPrefix("/") { return (reference as NSString).standardizingPath }
        guard let base, base.hasPrefix("/"), !reference.hasPrefix("~") else { return nil }
        let relative = reference.hasPrefix("./") ? String(reference.dropFirst(2)) : reference
        return ((base as NSString).appendingPathComponent(relative) as NSString).standardizingPath
    }

    /// Each load owns a separate copy so overlapping previews cannot replace a file
    /// another viewer is using. Only a completed part file is published to its URL.
    static func read(path: String, over link: any MacLink, macName: String, for artifact: TerminalArtifact,
                     capacity: PreviewStorage.Capacity = PreviewStorage.availableCapacity,
                     store: PreviewFileStore = .shared) async throws -> ManagedPreviewFile {
        let file = try store.make(name: ArtifactLocalCopy.safeName(artifact.name,
            defaultExtension: artifact.kind == .video ? "mp4" : nil))
        // Keep the owner registered across awaits, including cancellation/failure.
        defer { withExtendedLifetime(file) {} }
        let url = file.url
        let part = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
        let channel: any LinkChannel
        do {
            // New service negotiates the size header explicitly. Old hosts refuse the
            // service instead of having arbitrary file bytes mistaken for metadata.
            channel = try await link.openChannel(service: "file-preview", args: ["path": path])
        } catch let error as LinkError {
            throw Self.unavailable(error, path: path, macName: macName)
        }
        try await withTaskCancellationHandler {
            do {
                let size = try await previewSize(channel, path: path, macName: macName)
                _ = try await download(channel, to: part, path: path, macName: macName, expectedSize: size, capacity: capacity)
                try FileManager.default.moveItem(at: part, to: url)
            } catch {
                await channel.close(code: "cancelled", reason: "preview ended")
                throw error
            }
        } onCancel: {
            Task { await channel.close(code: "cancelled", reason: "preview cancelled") }
        }
        return file
    }

    static func previewSize(_ channel: any LinkChannel, path: String, macName: String) async throws -> Int64 {
        struct Metadata: Decodable { let size: Int64 }
        guard let header = try await receive(channel, within: idleTimeout, macName: macName) else {
            if let closed = channel.closedBy { throw unavailable(closed, path: path, macName: macName) }
            throw ArtifactUnavailable("Couldn't read the file size from \(macName).")
        }
        guard header.count <= 1024, let metadata = try? JSONDecoder().decode(Metadata.self, from: header),
              metadata.size >= 0 else {
            throw ArtifactUnavailable("Couldn't read the file size from \(macName).")
        }
        return metadata.size
    }

    /// Writes one bounded message at a time. Capacity is checked before creating the
    /// part file and before each write, including the remaining bytes and reserve.
    /// A capacity drop, cancellation, refusal or failed read closes the channel and
    /// removes the partial file; no attachment size limit is imposed.
    static func download(_ channel: any LinkChannel, to destination: URL, path: String, macName: String,
                         expectedSize: Int64? = nil,
                         capacity: PreviewStorage.Capacity = PreviewStorage.availableCapacity) async throws -> Int64 {
        var written: Int64 = 0
        var created = false
        do {
            try Task.checkCancellation()
            try PreviewStorage.check(destination, path: path, size: expectedSize ?? 0,
                                     remaining: expectedSize ?? 0, capacity: capacity)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ArtifactUnavailable("Couldn't save \((path as NSString).lastPathComponent) on this iPhone.")
            }
            created = true
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            do {
                while let chunk = try await Self.receive(channel, within: idleTimeout, macName: macName) {
                    try Task.checkCancellation()
                    if let expectedSize, Int64(chunk.count) > expectedSize - written {
                        throw ArtifactUnavailable("The file changed while downloading. Try again.")
                    }
                    try PreviewStorage.check(destination, path: path, size: expectedSize ?? written + Int64(chunk.count),
                                             remaining: expectedSize.map { $0 - written } ?? Int64(chunk.count), capacity: capacity)
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                }
            } catch let error as LinkError {
                throw Self.unavailable(error, path: path, macName: macName)
            }
            try Task.checkCancellation()
            if let closed = channel.closedBy, !closed.code.isEmpty, closed.code != "eof" {
                throw Self.unavailable(closed, path: path, macName: macName)
            }
            if let expectedSize, written != expectedSize {
                throw ArtifactUnavailable("The file changed while downloading. Try again.")
            }
        } catch {
            if created { try? FileManager.default.removeItem(at: destination) }
            await channel.close(code: "cancelled", reason: "preview ended")
            throw error
        }
        return written
    }

    /// How long a read may wait for its next bytes before the preview gives up (a Mac that
    /// went to sleep mid-read left "Loading" up for good).
    public static let idleTimeout: Duration = .seconds(20)

    /// The channel's next message, or a refusal after `limit` with nothing: the channel is
    /// closed so the read ends.
    static func receive(_ channel: any LinkChannel, within limit: Duration, macName: String,
                        clock: any Clock<Duration> = ContinuousClock()) async throws -> Data? {
        let stalled = ArtifactUnavailable("\(macName) stopped sending this file. Check that it's awake, then try again.")
        let timedOut = TimedOut()
        let next = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await channel.receive() }
            group.addTask {
                try await clock.sleep(for: limit)
                timedOut.set()
                await channel.close(code: "cancelled", reason: "timed out")
                throw stalled
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        // Closing the channel ends the receive with nil: that is the timeout, not the end of the file.
        if timedOut.value { throw stalled }
        return next
    }

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.withLock { fired = true } }
        var value: Bool { lock.withLock { fired } }
    }

    /// Where the person shares a folder: a workspace open on the Mac in that folder, or the Mac's
    /// Chat Folders setting (cmux-mobile-host's file roots and the Mac's workspace folders).
    static let shareHint = "Open a workspace in that folder on the Mac, or add it in Settings › General › Chats › Chat Folders."

    static func unavailable(_ error: LinkError, path: String, macName: String) -> ArtifactUnavailable {
        let name = (path as NSString).lastPathComponent
        return switch error.code {
        case "not_found": ArtifactUnavailable("\(name) isn't on \(macName) anymore.")
        case "forbidden" where error.message.contains("no workspace roots"):
            // cmux-mobile-host shares no folder at all (CMUX_MOBILE_FILE_ROOTS empty).
            // The Mac shares its Chat Folders (Settings › Chats): say where to add one.
            ArtifactUnavailable("\(macName) isn't sharing folders with this phone. \(Self.shareHint)")
        case "forbidden": ArtifactUnavailable("\(name) is outside the folders \(macName) shares with this phone. \(Self.shareHint)")
        case "bad_request": ArtifactUnavailable("\(name) isn't a regular file.")
        case "unknown_service": ArtifactUnavailable("Update cmux on \(macName) to preview this file.")
        default: ArtifactUnavailable(error.message.isEmpty ? "Couldn't read \(name) from \(macName)." : error.message)
        }
    }

    /// The preview for a local copy: text, images and PDFs up to ``inMemoryBytes`` are read
    /// into memory, everything else (and anything larger) previews from the file itself.
    static func content(for artifact: TerminalArtifact, file: ManagedPreviewFile) throws -> ArtifactContent {
        let size = (try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size == 0 { return try content(for: artifact, data: Data()) }
        switch artifact.kind {
        case .video:
            return .ownedFile(file, isVideo: true)
        case .audio, .document, .binary:
            return .ownedFile(file, isVideo: false)
        default:
            guard size <= inMemoryBytes else { return .ownedFile(file, isVideo: false) }
            let data = try Data(contentsOf: file.url)
            switch artifact.kind {
            case .image: return .image(data)
            case .pdf: return .pdf(data)
            default:
                // Reuse the owned copy for non-UTF8 text instead of leaking a second copy.
                guard let text = String(data: data, encoding: .utf8) else { return .ownedFile(file, isVideo: false) }
                return .text(text)
            }
        }
    }

    /// Decodes bytes into the preview the kind wants.
    public static func content(for artifact: TerminalArtifact, data: Data) throws -> ArtifactContent {
        if data.isEmpty {
            let shown = artifact.reference.hasPrefix(LocalFileArtifactSource.scheme) ? artifact.name : artifact.reference
            return .binary(description: "\(ArtifactContent.emptyFileLine)\n\(shown)")
        }
        switch artifact.kind {
        case .image:
            return .image(data)
        case .pdf:
            return .pdf(data)
        case .video:
            return .file(try ArtifactLocalCopy.write(data, for: artifact, defaultExtension: "mp4"))
        case .audio, .document, .binary:
            // Quick Look shows what it can (audio, Office and iWork, archives' listings);
            // the preview offers Share for the rest.
            return .quickLook(try ArtifactLocalCopy.write(data, for: artifact))
        default:
            guard let text = String(data: data, encoding: .utf8) else {
                // Named like text but not text (or a type the phone has no viewer for).
                return .quickLook(try ArtifactLocalCopy.write(data, for: artifact))
            }
            return .text(text)
        }
    }
}

/// A local copy of a preview's bytes under its own file name (Quick Look and
/// the share sheet go by the extension), one folder per reference.
public struct ArtifactLocalCopy: Sendable {
    public let url: URL

    /// The folder all copies live in (the system clears temporary files).
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("cmux-mobile-preview", isDirectory: true) }

    public static func write(_ data: Data, for artifact: TerminalArtifact, defaultExtension: String? = nil) throws -> URL {
        try ArtifactLocalCopy(data: data, name: artifact.name, key: artifact.reference, defaultExtension: defaultExtension).url
    }

    /// - Parameters:
    ///   - name: the file name the copy carries (a path separator in it is dropped).
    ///   - key: what makes two copies distinct (a reference or an attachment id).
    public init(data: Data, name: String, key: String, defaultExtension: String? = nil) throws {
        let url = try Self.destination(name: name, key: key, defaultExtension: defaultExtension)
        try data.write(to: url, options: .atomic)
        self.url = url
    }

    /// Where an artifact's copy goes (its folder is created), for a copy streamed to disk.
    static func destination(for artifact: TerminalArtifact, defaultExtension: String? = nil) throws -> URL {
        try destination(name: artifact.name, key: artifact.reference, defaultExtension: defaultExtension)
    }

    static func safeName(_ name: String, defaultExtension: String?) -> String {
        var safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if safe.isEmpty || safe == "." || safe == ".." { safe = "file" }
        if (safe as NSString).pathExtension.isEmpty, let defaultExtension { safe += "." + defaultExtension }
        return safe
    }

    static func destination(name: String, key: String, defaultExtension: String?) throws -> URL {
        let safe = safeName(name, defaultExtension: defaultExtension)
        let folder = root.appendingPathComponent(digest(key + "\u{0}" + safe), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(safe)
    }

    /// A stable folder name for a key (FNV-1a, hex): the same file reuses its copy.
    static func digest(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// Serves some references from data the session already holds (attachments,
/// images in tool output) and the rest from `fallback`.
public struct InlineArtifactSource: ArtifactSource {
    let inline: [String: ArtifactContent]
    let fallback: any ArtifactSource

    public init(inline: [String: ArtifactContent], fallback: any ArtifactSource) {
        self.inline = inline
        self.fallback = fallback
    }

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        if let content = inline[artifact.reference] { return content }
        return try await fallback.load(artifact)
    }
}
