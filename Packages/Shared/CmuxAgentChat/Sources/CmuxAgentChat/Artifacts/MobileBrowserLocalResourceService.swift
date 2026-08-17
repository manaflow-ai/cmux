import CMUXMobileCore
import Foundation
import UniformTypeIdentifiers

/// Filesystem policy and bounded reads for phone-local rendering of a Mac
/// browser file. Panel lookup and authentication remain in the app target.
public struct MobileBrowserLocalResourceService: Sendable {
    /// Errors that the app maps to its localized RPC vocabulary.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The logical path is not an absolute, non-empty resource path.
        case invalidPath
        /// The resolved path is not a regular file.
        case notRegularFile
        /// The file exceeds the per-resource transfer budget.
        case tooLarge
        /// The file could not be read due to permissions.
        case permissionDenied
        /// The file could not be read for another filesystem reason.
        case readFailed
    }

    private let policy: MobileBrowserLocalResourcePolicy
    private let reader: ArtifactByteReader

    /// Creates a bounded local-resource service.
    /// - Parameters:
    ///   - policy: Resource and chunk limits.
    ///   - reader: The already-authorized byte reader.
    public init(
        policy: MobileBrowserLocalResourcePolicy = .init(),
        reader: ArtifactByteReader = .init()
    ) {
        self.policy = policy
        self.reader = reader
    }

    /// Resolves and fetches one logical resource range beneath `readRoot`.
    /// - Parameters:
    ///   - path: The logical absolute path sent by the phone.
    ///   - readRoot: The Mac file's existing WebKit read-access root.
    ///   - offset: The non-negative byte offset.
    ///   - length: The requested byte count, clamped to the policy.
    /// - Returns: A bounded wire chunk with MIME metadata.
    /// - Throws: ``Error`` when validation, confinement, or reading fails.
    public func fetch(
        path: String,
        readRoot: URL,
        offset: Int64,
        length: Int
    ) throws -> MobileBrowserLocalResourceChunk {
        guard offset >= 0, length > 0,
              let resolvedURL = Self.resolve(path: path, beneath: readRoot) else {
            throw Error.invalidPath
        }
        let canonicalPath = resolvedURL.path
        let stat: ChatArtifactStat
        do {
            stat = try reader.stat(path: canonicalPath)
        } catch let error as ArtifactByteReader.Error {
            throw map(error)
        } catch {
            throw Error.readFailed
        }
        guard !stat.isDirectory else { throw Error.notRegularFile }
        guard stat.size >= 0, stat.size <= policy.maximumResourceBytes else {
            throw Error.tooLarge
        }
        let chunk: ChatArtifactChunk
        do {
            chunk = try reader.fetch(
                path: canonicalPath,
                offset: offset,
                length: min(length, policy.maximumChunkBytes)
            )
        } catch let error as ArtifactByteReader.Error {
            throw map(error)
        } catch {
            throw Error.readFailed
        }
        guard chunk.totalSize >= 0,
              chunk.totalSize <= policy.maximumResourceBytes,
              chunk.data.count <= policy.maximumChunkBytes else {
            throw Error.tooLarge
        }
        return MobileBrowserLocalResourceChunk(
            path: path,
            offset: chunk.offset,
            totalSize: chunk.totalSize,
            data: chunk.data,
            mimeType: stat.mimeType ?? Self.mimeType(for: resolvedURL),
            eof: chunk.eof
        )
    }

    /// Resolves a logical path beneath a canonicalized read root.
    /// - Parameters:
    ///   - path: An absolute logical path.
    ///   - readRoot: The root to which the result must remain confined.
    /// - Returns: A canonical regular-file candidate, or `nil` if it escapes.
    public static func resolve(path: String, beneath readRoot: URL) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let root = readRoot.resolvingSymlinksInPath().standardizedFileURL
        let relativePath = String(path.drop(while: { $0 == "/" }))
        guard !relativePath.isEmpty else { return nil }
        let candidate = root.appendingPathComponent(relativePath, isDirectory: false)
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path == "/" ? "/" : root.path + "/"
        guard canonical.path.hasPrefix(rootPrefix) else { return nil }
        return canonical
    }

    private static func mimeType(for url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return type.preferredMIMEType
    }

    private func map(_ error: ArtifactByteReader.Error) -> Error {
        switch error {
        case .permissionDenied:
            return .permissionDenied
        case .notRegularFile:
            return .notRegularFile
        case .fileNotFound, .notDirectory, .unsupportedMedia, .corruptMedia,
             .previewFailed, .readFailed:
            return .readFailed
        }
    }
}
