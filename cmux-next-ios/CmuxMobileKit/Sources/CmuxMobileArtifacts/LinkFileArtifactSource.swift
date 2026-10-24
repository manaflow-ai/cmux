import CmuxMobileTransport
import Foundation

/// Reads artifacts from the Mac over the link's `file` service (PROTOCOL.md):
/// one channel per file, opened with `{"path": <absolute path>}`, data frames
/// until the Mac closes it with `eof`. The Mac confines reads to workspace
/// roots and refuses folders, so folders and paths outside a root explain why.
public struct LinkFileArtifactSource: ArtifactSource {
    /// The connected Mac's link, or nil while offline.
    let link: @Sendable () async -> (any MacLink)?
    /// Resolves relative references (the session's working directory).
    let baseDirectory: String?
    let macName: String
    /// Largest file the preview reads (the rest is never requested).
    public static let maxBytes = 24 << 20

    public init(macName: String, baseDirectory: String?, link: @escaping @Sendable () async -> (any MacLink)?) {
        self.link = link
        self.baseDirectory = baseDirectory
        self.macName = macName
    }

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        switch artifact.kind {
        case .link:
            guard let url = URL(string: artifact.reference) else { throw ArtifactNotFound(reference: artifact.reference) }
            return .web(url)
        case .directory:
            throw ArtifactUnavailable("Folder listings aren't available from \(macName) yet. Open a file inside it instead.")
        default:
            break
        }
        guard let path = Self.absolutePath(artifact.reference, base: baseDirectory) else {
            throw ArtifactUnavailable("\(artifact.reference) isn't inside a known folder on \(macName).")
        }
        guard let link = await link() else {
            throw ArtifactUnavailable("Connect to \(macName) to open \(artifact.name).")
        }
        let data = try await Self.read(path: path, over: link, macName: macName)
        return try Self.content(for: artifact, data: data)
    }

    /// Absolute path for a reference: absolute stays, `./x` and `x/y` join the base; `~` can't be resolved here.
    public static func absolutePath(_ reference: String, base: String?) -> String? {
        if reference.hasPrefix("/") { return (reference as NSString).standardizingPath }
        guard let base, base.hasPrefix("/"), !reference.hasPrefix("~") else { return nil }
        let relative = reference.hasPrefix("./") ? String(reference.dropFirst(2)) : reference
        return ((base as NSString).appendingPathComponent(relative) as NSString).standardizingPath
    }

    static func read(path: String, over link: any MacLink, macName: String) async throws -> Data {
        let channel: any LinkChannel
        do {
            channel = try await link.openChannel(service: "file", args: ["path": path])
        } catch let error as LinkError {
            throw Self.unavailable(error, path: path, macName: macName)
        }
        var data = Data()
        do {
            while let chunk = try await Self.receive(channel, within: idleTimeout, macName: macName) {
                data.append(chunk)
                if data.count > maxBytes {
                    await channel.close(code: "cancelled", reason: "preview limit")
                    throw ArtifactUnavailable("This file is larger than \(maxBytes >> 20) MB, too large to preview on the phone.")
                }
            }
        } catch let error as LinkError {
            throw Self.unavailable(error, path: path, macName: macName)
        }
        // The Mac refuses by closing the channel (outside the shared
        // folders, missing, a folder): without this the refusal read as an
        // empty file and the preview stayed blank.
        if let closed = channel.closedBy, !closed.code.isEmpty, closed.code != "eof" {
            throw Self.unavailable(closed, path: path, macName: macName)
        }
        return data
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
    static let shareHint = "To open it here, open a workspace in its project folder on the Mac, or add the folder in cmux on the Mac: Settings › General › Chats › Chat Folders."

    static func unavailable(_ error: LinkError, path: String, macName: String) -> ArtifactUnavailable {
        let name = (path as NSString).lastPathComponent
        return switch error.code {
        case "not_found": ArtifactUnavailable("\(name) isn't on \(macName) anymore.")
        case "forbidden" where error.message.contains("no workspace roots"):
            // cmux-mobile-host shares no folder at all (CMUX_MOBILE_FILE_ROOTS empty).
            // The Mac shares its Chat Folders (Settings › Chats): say where to add one.
            ArtifactUnavailable("\(macName) isn't sharing any folders with this phone yet, so \(name) can't be opened here. \(Self.shareHint)")
        case "forbidden": ArtifactUnavailable("\(name) is outside the folders \(macName) shares with this phone. \(Self.shareHint)")
        case "bad_request": ArtifactUnavailable("\(name) isn't a regular file.")
        case "unknown_service": ArtifactUnavailable("\(macName) doesn't serve files yet. Update cmux on the Mac.")
        default: ArtifactUnavailable(error.message.isEmpty ? "Couldn't read \(name) from \(macName)." : error.message)
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
        var safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if safe.isEmpty || safe == "." || safe == ".." { safe = "file" }
        if (safe as NSString).pathExtension.isEmpty, let defaultExtension { safe += "." + defaultExtension }
        let folder = Self.root.appendingPathComponent(Self.digest(key + "\u{0}" + safe), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(safe)
        try data.write(to: url, options: .atomic)
        self.url = url
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
