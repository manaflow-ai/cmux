import CryptoKit
import Darwin
import Foundation

nonisolated enum FileOpenFailure: Error, Sendable, Equatable {
    case notFound
    /// A folder, a package or another non-regular file.
    case notFile
    case tooLarge
}

nonisolated enum FileSaveFailure: Error, Sendable, Equatable {
    case readOnly
    /// The file's hash is not the page's base hash: what the file holds now.
    case conflict(hash: String, text: String)
    /// The page's file is gone.
    case deleted
    /// The write itself failed (disk full, the folder went away).
    case failed(String)
}

/// The file pages' disk rules (diff-host S6, S7), shared by the markdown and the code editor
/// page: read and decode, hash, and the save that writes exactly what the page sent, only on its
/// base hash, through a temporary file and a rename.
nonisolated enum FileDocument {
    /// The largest file a page opens (Monaco refuses heap operations above 256M characters).
    static let maximumBytes = 200 * 1024 * 1024
    /// The bytes git checks for a NUL to call a file binary.
    static let binaryProbeBytes = 8000

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isBinary(_ bytes: Data) -> Bool {
        bytes.prefix(binaryProbeBytes).contains(0)
    }

    /// The text and whether it is the bytes exactly (valid UTF-8).
    static func decode(_ bytes: Data) -> (text: String, exact: Bool) {
        let text = String(decoding: bytes, as: UTF8.self)
        return (text, text.utf8.elementsEqual(bytes))
    }

    /// Reads `url` (links resolved). `inWorkspace`: some workspace root contains it.
    static func read(_ url: URL, inWorkspace: Bool, maximumBytes: Int = maximumBytes) throws(FileOpenFailure) -> FileSnapshot {
        let real = url.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard stat(real.path, &info) == 0 else { throw .notFound }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notFile }
        guard Int(info.st_size) <= maximumBytes else { throw .tooLarge }
        // concurrency-allow: FileDocument is nonisolated; the pages call it from @concurrent functions only
        guard let bytes = try? Data(contentsOf: real, options: .mappedIfSafe) else { throw .notFound }
        let (text, exact) = decode(bytes)
        let reason: FileReadOnlyReason? = if isBinary(bytes) {
            .binary
        } else if !exact {
            .encoding
        } else if !inWorkspace {
            .outside
        } else if access(real.path, W_OK) != 0 {
            .permission
        } else {
            nil
        }
        return FileSnapshot(url: real, text: text, hash: hash(bytes), size: bytes.count, readOnlyReason: reason)
    }

    /// The file now, nil when it is gone (or no longer a readable regular file).
    static func current(_ url: URL, inWorkspace: Bool) -> FileSnapshot? {
        try? read(url, inWorkspace: inWorkspace)
    }

    /// `cmux.<page>.save`: writes `text` as UTF-8 when the file's hash is `baseHash` (nil: only
    /// while the file does not exist). Bytes equal to the file's are not written.
    static func save(_ text: String, to url: URL, baseHash: String?, inWorkspace: Bool) throws(FileSaveFailure) -> FileSaveResult {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let current: FileSnapshot?
        do {
            current = try read(target, inWorkspace: inWorkspace)
        } catch .notFound {
            current = nil
        } catch {
            throw .readOnly
        }
        if let current, current.readOnlyReason != nil { throw .readOnly }
        if current == nil, !inWorkspace { throw .readOnly }
        guard current?.hash == baseHash else {
            guard let current else { throw .deleted }
            throw .conflict(hash: current.hash, text: current.text)
        }
        let bytes = Data(text.utf8)
        let newHash = hash(bytes)
        if let current, current.hash == newHash { return FileSaveResult(hash: newHash, written: false) }
        do {
            try atomicWrite(bytes, to: target)
        } catch {
            throw .failed(String(describing: error))
        }
        return FileSaveResult(hash: newHash, written: true)
    }

    nonisolated struct WriteError: Error, CustomStringConvertible {
        let step: String
        let code: Int32
        var description: String { "\(step): \(String(cString: strerror(code)))" }
    }

    /// Writes `bytes` to a temporary file beside `target`, gives it the file's permissions and
    /// extended attributes, then renames it over `target`, so a reader never sees half a file.
    static func atomicWrite(_ bytes: Data, to target: URL) throws {
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appending(path: ".\(target.lastPathComponent).cmux-save-\(UUID().uuidString.prefix(8))")
        var info = stat()
        let exists = stat(target.path, &info) == 0
        let mode = exists ? mode_t(info.st_mode & 0o7777) : 0o644
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw WriteError(step: "open", code: errno) }
        var renamed = false
        defer {
            if !renamed { unlink(temporary.path) }
        }
        do {
            defer { close(descriptor) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    // concurrency-allow: atomicWrite runs inside FileDocument.save, which the pages call from @concurrent functions
                    let written = write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw WriteError(step: "write", code: errno)
                    }
                    offset += written
                }
            }
            if exists {
                // open(2) applies the umask; the saved file keeps its exact mode.
                guard fchmod(descriptor, mode) == 0 else { throw WriteError(step: "fchmod", code: errno) }
                copyExtendedAttributes(from: target.path, to: descriptor)
            }
            guard fsync(descriptor) == 0 else { throw WriteError(step: "fsync", code: errno) }
        }
        guard rename(temporary.path, target.path) == 0 else { throw WriteError(step: "rename", code: errno) }
        renamed = true
    }

    /// Copies every extended attribute of `path` (tags, the quarantine flag, a Finder comment).
    /// An attribute that fails to copy is skipped: the text still saves.
    private static func copyExtendedAttributes(from path: String, to descriptor: Int32) {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return }
        let joined = names.split(separator: 0, omittingEmptySubsequences: true)
        for name in joined {
            let key = String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let length = getxattr(path, key, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: max(length, 1))
            let read = getxattr(path, key, &value, length, 0, XATTR_NOFOLLOW)
            guard read == length else { continue }
            _ = fsetxattr(descriptor, key, value, length, 0, 0)
        }
    }
}
