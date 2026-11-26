import CmuxFoundation
import Darwin
import Foundation

/// Reads only Codex's ownership records, independently of the global process census.
actor CodexRestoreHookEvidence {
    struct Result: Sendable {
        let owner: LiveAgentSessionOwner?
        let isComplete: Bool
    }

    private struct Store: Decodable {
        let version: Int
        let sessions: [String: RestorableAgentHookSessionRecord]
    }

    private let storeURL: URL
    private var cachedStore: Store?
    private var cachedFingerprint: String?

    init(storeURL: URL) { self.storeURL = storeURL }

    func load(
        sessionID: String,
        processIdentity: @Sendable (Int) -> AgentPIDProcessIdentity?
    ) -> Result {
        let descriptor = open(storeURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return Result(owner: nil, isComplete: errno == ENOENT)
        }
        defer { close(descriptor) }
        var before = stat()
        let limit = 16 * 1_024 * 1_024
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= Int64(limit) else {
            return Result(owner: nil, isComplete: false)
        }
        let fingerprint = "\(before.st_dev):\(before.st_ino):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec)"
        let store: Store
        if fingerprint == cachedFingerprint, let cachedStore {
            store = cachedStore
        } else {
            var bytes = [UInt8](repeating: 0, count: Int(before.st_size) + 1)
            var count = 0
            while count < bytes.count {
                let received = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                }
                if received < 0, errno == EINTR { continue }
                guard received >= 0 else { return Result(owner: nil, isComplete: false) }
                if received == 0 { break }
                count += received
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_size == after.st_size, count == Int(before.st_size),
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  let decoded = try? JSONDecoder().decode(Store.self, from: Data(bytes.prefix(count))),
                  decoded.version == 1 else { return Result(owner: nil, isComplete: false) }
            store = decoded
            cachedStore = decoded
            cachedFingerprint = fingerprint
        }
        // A process can switch conversations without changing PID. Reduce all
        // observations by generation before selecting the requested session.
        let observations = store.sessions.values.compactMap { record -> LiveAgentSessionOwnerObservation? in
            guard let workspaceID = UUID(uuidString: record.workspaceId),
                  let surfaceID = UUID(uuidString: record.surfaceId) else { return nil }
            return LiveAgentSessionOwnerObservation.validatingHookRecord(
                snapshot: SessionRestorableAgentSnapshot(
                    kind: .codex, sessionId: record.sessionId, workingDirectory: record.cwd,
                    launchCommand: record.launchCommand
                ),
                record: record, workspaceID: workspaceID, surfaceID: surfaceID,
                processArgumentsProvider: { _ in nil }, processIdentityProvider: processIdentity,
                validator: CachedAgentProcessIdentityValidator()
            )
        }
        return Result(
            owner: LiveAgentSessionOwnerIndex(observations: observations).owner(
                kind: "codex", sessionID: sessionID, processIdentityProvider: processIdentity
            ),
            isComplete: true
        )
    }
}
