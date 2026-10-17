import CmuxConversation
import CryptoKit
import Darwin
import Foundation

/// Pins bounded artifacts from a journaled session. The caller authorizes the
/// session/workspace; this owner restricts reads to regular descendants of its
/// trusted directory and prevents symlink traversal at every child component.
actor NativeConversationArtifactStore {
    private struct PinnedArtifact {
        let bytes: Data
        let sha256: String
        let fileName: String
    }

    private var pinned: [String: PinnedArtifact] = [:]
    private var accessOrder: [String] = []
    private var readsInFlight = 0
    private let maximumBytes = 16_777_216
    private let maximumCacheBytes = 67_108_864

    func chunk(query: ConversationArtifactQuery, snapshot: ConversationSnapshot) async throws -> ConversationArtifactChunk {
        guard query.sessionID == snapshot.session.id,
              let artifact = snapshot.items.compactMap(\.artifact).first(where: { $0.artifactID == query.artifactID }),
              let source = artifact.remoteURL, let url = URL(string: source), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else {
            throw NativeConversationError.invalidScope
        }
        let key = "\(snapshot.session.id.rawValue)|\(snapshot.generation)|\(artifact.artifactID)|\(source)"
        let entry: PinnedArtifact
        if let cached = pinned[key] {
            entry = cached
        } else {
            guard readsInFlight < 2 else { throw NativeConversationError.invalidPayload }
            readsInFlight += 1
            defer { readsInFlight -= 1 }
            let directory = snapshot.session.directory
            let limit = maximumBytes
            let bytes = try await Task.detached(priority: .utility) {
                try Self.readRegularDescendant(directory: directory, path: url.path, limit: limit)
            }.value
            guard bytes.count <= maximumBytes else { throw NativeConversationError.invalidPayload }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if let expected = artifact.sha256, expected.lowercased() != digest {
                throw NativeConversationError.invalidPayload
            }
            if let count = artifact.byteCount, count != bytes.count {
                throw NativeConversationError.invalidPayload
            }
            entry = PinnedArtifact(bytes: bytes, sha256: digest, fileName: url.lastPathComponent)
            while (pinned.count >= 64 || pinned.values.reduce(0, { $0 + $1.bytes.count }) + bytes.count > maximumCacheBytes),
                  let oldest = accessOrder.first {
                pinned[oldest] = nil
                accessOrder.removeFirst()
            }
            pinned[key] = entry
        }
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        guard query.offset <= UInt64(entry.bytes.count),
              query.offset == 0 || query.expectedSHA256 == entry.sha256,
              query.expectedSHA256 == nil || query.expectedSHA256 == entry.sha256 else {
            throw NativeConversationError.invalidPayload
        }
        let start = Int(query.offset)
        let end = min(start + 65_536, entry.bytes.count)
        return ConversationArtifactChunk(
            artifactID: artifact.artifactID, fileName: entry.fileName, offset: query.offset,
            totalBytes: UInt64(entry.bytes.count), sha256: entry.sha256, data: entry.bytes.subdata(in: start..<end)
        )
    }

    private nonisolated static func readRegularDescendant(directory: String, path: String, limit: Int) throws -> Data {
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { throw NativeConversationError.invalidScope }
        let components = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw NativeConversationError.invalidScope
        }
        let trustedRoot = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().path
        var descriptor = open(trustedRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeConversationError.invalidScope }
        defer { _ = close(descriptor) }
        for component in components.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw NativeConversationError.invalidScope }
            _ = close(descriptor)
            descriptor = next
        }
        guard let leaf = components.last else { throw NativeConversationError.invalidScope }
        let file = openat(descriptor, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw NativeConversationError.invalidScope }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw NativeConversationError.invalidPayload }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, data.count == info.st_size else { throw NativeConversationError.invalidPayload }
        return data
    }
}
