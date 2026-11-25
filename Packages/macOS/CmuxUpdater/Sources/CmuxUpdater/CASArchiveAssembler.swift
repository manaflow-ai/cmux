public import Foundation
import CryptoKit

/// Rebuilds a Sparkle update archive bit-exact from content-addressed chunks (RFD 0166 row 303, U3).
///
/// The publisher writes a `cmux-cas-manifest/0` JSON next to each archive (`scripts/cas/mac_archive_manifest.py`):
/// the archive's size and sha256 plus its FastCDC chunks in order, each named by its sha256. The assembler
/// reuses chunks already in the local store, fetches the rest from the chunk base URL, checks every
/// chunk and the whole file, and only then hands back a file. Sparkle still verifies its EdDSA
/// signature over that file, which passes because the bytes are the published archive's.
///
/// Off by default: ``isEnabled(in:)`` reads ``enabledKey`` and nothing calls the assembler unless it is set.
public struct CASArchiveAssembler: Sendable {
    /// `UserDefaults` key that turns CAS assembly on (`defaults write <bundle> cmux.update.casAssembly -bool YES`).
    public static let enabledKey = "cmux.update.casAssembly"

    /// The manifest format this assembler reads.
    public static let manifestFormat = "cmux-cas-manifest/0"

    /// One chunk of the archive, in order.
    public struct Chunk: Decodable, Equatable, Sendable {
        /// Lowercase hex sha256 of the chunk's bytes; also its store name.
        public let sha256: String
        /// The chunk's length in bytes.
        public let size: Int
    }

    /// A `cmux-cas-manifest/0` document.
    public struct Manifest: Decodable, Equatable, Sendable {
        /// The format tag; must equal ``CASArchiveAssembler/manifestFormat``.
        public let format: String
        /// The archive's length in bytes.
        public let size: Int
        /// Lowercase hex sha256 of the whole archive.
        public let sha256: String
        /// The chunks, concatenated in this order to form the archive.
        public let chunks: [Chunk]
    }

    /// Why an assembly did not produce a file. Every case means: let Sparkle download the archive itself.
    public enum Failure: Error, Equatable, Sendable {
        /// The manifest's format tag is not ``CASArchiveAssembler/manifestFormat``.
        case unsupportedFormat(String)
        /// The chunk sizes do not add up to the manifest's size.
        case sizeMismatch
        /// A chunk's bytes do not hash to its name.
        case chunkDigestMismatch(String)
        /// The assembled file does not hash to the manifest's sha256.
        case archiveDigestMismatch
        /// A chunk could not be fetched.
        case fetchFailed(String)
    }

    /// Fetches one chunk's bytes by sha256 from the remote store.
    public typealias ChunkFetcher = @Sendable (String) async throws -> Data

    /// Where chunks live locally, as `store/xx/<sha256>`.
    public let store: URL
    private let fetch: ChunkFetcher

    /// Creates an assembler over a local chunk store and a remote fetcher.
    public init(store: URL, fetch: @escaping ChunkFetcher) {
        self.store = store
        self.fetch = fetch
    }

    /// Whether CAS assembly is turned on in `defaults`. False unless ``enabledKey`` is set.
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Decodes and sanity-checks a manifest.
    public static func decodeManifest(_ data: Data) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.format == manifestFormat else {
            throw Failure.unsupportedFormat(manifest.format)
        }
        guard manifest.chunks.reduce(0, { $0 + $1.size }) == manifest.size else {
            throw Failure.sizeMismatch
        }
        return manifest
    }

    /// The bytes a client must fetch for `manifest`: the total size of the chunks not in the store.
    public func missingBytes(for manifest: Manifest) -> Int {
        var seen = Set<String>()
        return manifest.chunks.reduce(0) { total, chunk in
            guard seen.insert(chunk.sha256).inserted, !hasChunk(chunk.sha256) else { return total }
            return total + chunk.size
        }
    }

    /// Assembles `manifest` into `destination`, fetching missing chunks into the store first.
    ///
    /// The file appears at `destination` only after its whole sha256 matches; on any failure nothing is left there.
    public func assemble(_ manifest: Manifest, to destination: URL) async throws {
        for chunk in manifest.chunks where !hasChunk(chunk.sha256) {
            let data: Data
            do {
                data = try await fetch(chunk.sha256)
            } catch {
                throw Failure.fetchFailed(chunk.sha256)
            }
            guard data.count == chunk.size, Self.hex(SHA256.hash(data: data)) == chunk.sha256 else {
                throw Failure.chunkDigestMismatch(chunk.sha256)
            }
            try put(chunk.sha256, data)
        }

        let fm = FileManager.default
        let partial = destination.appendingPathExtension("part")
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: partial)
        var whole = SHA256()
        do {
            for chunk in manifest.chunks {
                let data = try Data(contentsOf: chunkURL(chunk.sha256))
                guard Self.hex(SHA256.hash(data: data)) == chunk.sha256 else {
                    throw Failure.chunkDigestMismatch(chunk.sha256)
                }
                whole.update(data: data)
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: partial)
            throw error
        }
        guard Self.hex(whole.finalize()) == manifest.sha256 else {
            try? fm.removeItem(at: partial)
            throw Failure.archiveDigestMismatch
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
    }

    func chunkURL(_ sha256: String) -> URL {
        store.appendingPathComponent(String(sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent(sha256, isDirectory: false)
    }

    func hasChunk(_ sha256: String) -> Bool {
        FileManager.default.fileExists(atPath: chunkURL(sha256).path)
    }

    /// Writes a verified chunk into the store. The store is content-addressed, so a chunk another
    /// writer already placed is success; each writer uses its own temporary name.
    func put(_ sha256: String, _ data: Data) throws {
        let dest = chunkURL(sha256)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { return }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.deletingLastPathComponent().appendingPathComponent("\(sha256).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        do {
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            if !fm.fileExists(atPath: dest.path) { throw error }
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
