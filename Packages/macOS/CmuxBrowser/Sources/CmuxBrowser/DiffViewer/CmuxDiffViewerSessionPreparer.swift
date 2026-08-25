import Darwin
public import Foundation

/// Performs the bounded synchronous filesystem work needed to prepare a session.
///
/// Call these methods from a socket worker or detached task, never from the main
/// actor. Manifest bytes, entry count, file locations, file kinds, readability,
/// MIME types, duplicates, and the shared lease are all validated before a
/// ``CmuxDiffViewerPreparedSession`` is returned.
public struct CmuxDiffViewerSessionPreparer: Sendable {
    /// Matches the maximum accepted by `Native/DiffSidecar` and the CLI writer.
    public static let defaultMaximumRegisteredFiles = 4096

    /// Bounds memory before manifest JSON decoding. This accommodates 4096 long paths.
    public static let defaultMaximumManifestBytes = 16 * 1024 * 1024

    /// The per-user directory used by the CLI and sidecar.
    public static var defaultTrustedRootURL: URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .standardizedFileURL
    }

    private let trustedRootURL: URL
    private let maximumRegisteredFiles: Int
    private let maximumManifestBytes: Int

    /// Creates a preparer with explicit resource limits.
    ///
    /// - Parameters:
    ///   - trustedRootURL: Current-user-owned directory containing all session files.
    ///   - maximumRegisteredFiles: Maximum number of allowlist entries.
    ///   - maximumManifestBytes: Maximum bytes read before JSON decoding.
    public init(
        trustedRootURL: URL = Self.defaultTrustedRootURL,
        maximumRegisteredFiles: Int = Self.defaultMaximumRegisteredFiles,
        maximumManifestBytes: Int = Self.defaultMaximumManifestBytes
    ) {
        self.trustedRootURL = trustedRootURL.standardizedFileURL
        self.maximumRegisteredFiles = max(1, maximumRegisteredFiles)
        self.maximumManifestBytes = max(1, maximumManifestBytes)
    }

    /// Validates caller-supplied files and acquires the token's shared session lease.
    ///
    /// This method performs synchronous filesystem I/O and must run off the main actor.
    ///
    /// - Parameters:
    ///   - token: Capability token naming the session.
    ///   - files: Untrusted allowlist entries to validate and canonicalize.
    ///   - now: Timestamp stored on the prepared session for expiration.
    /// - Returns: A value-only session retaining its shared filesystem lease.
    /// - Throws: ``CmuxDiffViewerSessionError`` or a lease acquisition error.
    public func prepare(
        token: String,
        files: [CmuxDiffViewerRegisteredFile],
        now: Date = Date()
    ) throws -> CmuxDiffViewerPreparedSession {
        guard Self.isValidToken(token) else {
            throw CmuxDiffViewerSessionError.invalidToken
        }
        guard !files.isEmpty else {
            throw CmuxDiffViewerSessionError.emptyAllowlist
        }
        guard files.count <= maximumRegisteredFiles else {
            throw CmuxDiffViewerSessionError.allowlistTooLarge
        }

        let canonicalRoot = try validatedCanonicalRoot()
        var filesByPath: [String: CmuxDiffViewerRegisteredFile] = [:]
        var restorableRequestPaths: Set<String> = []
        var fileSizes: [URL: Int] = [:]
        var restorableHTMLByURL: [URL: Bool] = [:]
        filesByPath.reserveCapacity(files.count)

        for file in files {
            guard Self.isValidRequestPath(file.requestPath),
                  Self.isAllowedMimeType(file.mimeType),
                  Self.pathExtensionMatchesMimeType(
                      path: file.requestPath,
                      mimeType: file.mimeType
                  ) else {
                throw CmuxDiffViewerSessionError.invalidEntry
            }
            guard filesByPath[file.requestPath] == nil else {
                throw CmuxDiffViewerSessionError.duplicateEntry
            }

            let canonicalFileURL = file.fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isFile(canonicalFileURL, within: canonicalRoot) else {
                throw CmuxDiffViewerSessionError.unreadableFile
            }
            let fileSize: Int
            if let cachedSize = fileSizes[canonicalFileURL] {
                fileSize = cachedSize
            } else {
                guard let validatedSize = Self.readableRegularFileSize(at: canonicalFileURL) else {
                    throw CmuxDiffViewerSessionError.unreadableFile
                }
                fileSizes[canonicalFileURL] = validatedSize
                fileSize = validatedSize
            }
            let preparedFile = CmuxDiffViewerRegisteredFile(
                requestPath: file.requestPath,
                fileURL: canonicalFileURL,
                mimeType: file.mimeType,
                fileSize: fileSize
            )
            filesByPath[file.requestPath] = preparedFile
            if file.mimeType == "text/html" {
                let isRestorable = restorableHTMLByURL[canonicalFileURL]
                    ?? Self.isRestorableHTML(at: canonicalFileURL)
                restorableHTMLByURL[canonicalFileURL] = isRestorable
                if isRestorable {
                    restorableRequestPaths.insert(file.requestPath)
                }
            }
        }

        let lease = try CmuxDiffViewerSessionLease(root: canonicalRoot, token: token)
        return CmuxDiffViewerPreparedSession(
            token: token,
            filesByPath: filesByPath,
            restorableRequestPaths: restorableRequestPaths,
            createdAt: now,
            lease: lease
        )
    }

    /// Loads a token-bound local manifest within the byte limit and prepares its session.
    ///
    /// Remote patch entries are rejected because the custom scheme only serves local files.
    /// This method performs synchronous filesystem I/O and must run off the main actor.
    ///
    /// - Parameters:
    ///   - token: Capability token used to locate and validate the manifest.
    ///   - now: Timestamp stored on the prepared session for expiration.
    /// - Returns: A prepared local-only session retaining its shared filesystem lease.
    /// - Throws: ``CmuxDiffViewerSessionError`` or a lease acquisition error.
    public func prepareFromManifest(
        token: String,
        now: Date = Date()
    ) throws -> CmuxDiffViewerPreparedSession {
        guard Self.isValidToken(token) else {
            throw CmuxDiffViewerSessionError.invalidToken
        }
        let canonicalRoot = try validatedCanonicalRoot()
        let manifestURL = canonicalRoot
            .appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        let data = try Self.readBoundedFile(
            at: manifestURL,
            maximumBytes: maximumManifestBytes,
            tooLargeError: CmuxDiffViewerSessionError.manifestTooLarge
        )
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw CmuxDiffViewerSessionError.invalidManifest
        }
        guard manifest.token == token else {
            throw CmuxDiffViewerSessionError.invalidManifest
        }
        guard manifest.files.count <= maximumRegisteredFiles else {
            throw CmuxDiffViewerSessionError.allowlistTooLarge
        }

        let files = try manifest.files.map { entry in
            guard entry.remoteURL == nil, !entry.filePath.isEmpty else {
                throw CmuxDiffViewerSessionError.invalidManifest
            }
            return CmuxDiffViewerRegisteredFile(
                requestPath: entry.requestPath,
                fileURL: URL(fileURLWithPath: entry.filePath, isDirectory: false),
                mimeType: entry.mimeType
            )
        }
        return try prepare(token: token, files: files, now: now)
    }

    /// Returns whether a capability token is safe to embed as a scheme host and filename suffix.
    ///
    /// - Parameter token: Candidate token to validate.
    /// - Returns: `true` when the token satisfies the length and character constraints.
    public static func isValidToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard (16...80).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D:
                true
            default:
                false
            }
        }
    }

    /// Returns whether a percent-encoded absolute request path has no traversal components.
    ///
    /// - Parameter path: Candidate absolute custom-scheme path.
    /// - Returns: `true` when every component is nonempty and traversal-free.
    public static func isValidRequestPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("//") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private func validatedCanonicalRoot() throws -> URL {
        var info = stat()
        guard lstat(trustedRootURL.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == Darwin.getuid() else {
            throw CmuxDiffViewerSessionError.unsafeTrustedRoot
        }
        return trustedRootURL.resolvingSymlinksInPath()
    }

    private static func isFile(_ fileURL: URL, within rootURL: URL) -> Bool {
        fileURL.isFileURL && fileURL.path.hasPrefix(rootURL.path + "/")
    }

    private static func readableRegularFileSize(at fileURL: URL) -> Int? {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              access(fileURL.path, R_OK) == 0,
              info.st_size >= 0,
              UInt64(info.st_size) <= UInt64(Int.max) else {
            return nil
        }
        return Int(info.st_size)
    }

    private static func isRestorableHTML(at fileURL: URL) -> Bool {
        guard let head = try? readBoundedFile(
            at: fileURL,
            maximumBytes: 1024,
            allowTruncation: true,
            tooLargeError: CmuxDiffViewerSessionError.manifestTooLarge
        ),
        let text = String(data: head, encoding: .utf8) else {
            return false
        }
        return !text.contains("data-cmux-diff-pending=\"true\"")
            && !text.contains("data-cmux-diff-redirect")
    }

    private static func readBoundedFile(
        at fileURL: URL,
        maximumBytes: Int,
        allowTruncation: Bool = false,
        tooLargeError: any Error
    ) throws -> Data {
        let fileDescriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            throw CmuxDiffViewerSessionError.invalidManifest
        }
        defer { Darwin.close(fileDescriptor) }

        var info = stat()
        guard fstat(fileDescriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw CmuxDiffViewerSessionError.invalidManifest
        }
        if !allowTruncation, info.st_size > maximumBytes {
            throw tooLargeError
        }

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        var data = Data()
        let readLimit = allowTruncation ? maximumBytes : maximumBytes + 1
        while data.count < readLimit {
            let count = min(64 * 1024, readLimit - data.count)
            let chunk = try handle.read(upToCount: count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        if !allowTruncation, data.count > maximumBytes {
            throw tooLargeError
        }
        return data
    }

    private static func isAllowedMimeType(_ mimeType: String) -> Bool {
        mimeType == "text/html" || mimeType == "text/javascript" || mimeType == "text/x-diff"
    }

    private static func pathExtensionMatchesMimeType(path: String, mimeType: String) -> Bool {
        switch mimeType {
        case "text/html":
            path.hasSuffix(".html")
        case "text/javascript":
            path.hasSuffix(".mjs") || path.hasSuffix(".js")
        case "text/x-diff":
            path.hasSuffix(".patch")
        default:
            false
        }
    }

    private struct Manifest: Decodable {
        let token: String
        let files: [ManifestEntry]
    }

    private struct ManifestEntry: Decodable {
        let requestPath: String
        let filePath: String
        let mimeType: String
        let remoteURL: String?

        private enum CodingKeys: String, CodingKey {
            case requestPath = "request_path"
            case filePath = "file_path"
            case mimeType = "mime_type"
            case remoteURL = "remote_url"
        }
    }
}
