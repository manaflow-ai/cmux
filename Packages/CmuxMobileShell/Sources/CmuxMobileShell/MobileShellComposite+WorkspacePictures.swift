import CmuxMobileRPC
import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// Workspace-picture (iMessage-style avatar) fetch and cache for the mobile
/// shell. The workspace-list payload carries only a content hash per workspace;
/// the bytes are fetched once per hash via `mobile.workspace.picture.get` and
/// cached (stored state lives in `MobileShellComposite.swift`), so an unchanged
/// avatar is never re-sent and the per-frame stream stays untouched.
extension MobileShellComposite {
    /// Hard cap on accepted avatar bytes, mirroring the Mac store's stored-PNG
    /// cap. Enforced client-side so a buggy or hostile host can't grow the
    /// cache with oversized payloads.
    nonisolated static var maxWorkspacePictureBytes: Int { 512 * 1024 }

    /// Kick off fetches for any workspace picture whose hash is not yet cached.
    /// Idempotent and de-duplicated: each hash fetches at most once. The bytes are
    /// fetched on demand (not in the list payload) so `workspace.updated` stays
    /// small and an unchanged avatar is never re-sent.
    func fetchMissingWorkspacePictures() {
        guard let client = remoteClient else { return }
        var pending: [(workspaceID: String, hash: String)] = []
        var seenHashes: Set<String> = []
        for workspace in workspaces {
            guard let hash = workspace.pictureHash,
                  workspacePictureBytesByHash[hash] == nil,
                  !workspacePictureFetchInFlight.contains(hash),
                  seenHashes.insert(hash).inserted else {
                continue
            }
            pending.append((workspace.id.rawValue, hash))
        }
        guard !pending.isEmpty else { return }
        for entry in pending {
            workspacePictureFetchInFlight.insert(entry.hash)
        }
        Task { @MainActor [weak self] in
            for entry in pending {
                await self?.fetchWorkspacePicture(
                    client: client,
                    workspaceID: entry.workspaceID,
                    hash: entry.hash
                )
            }
        }
    }

    private func fetchWorkspacePicture(
        client: MobileCoreRPCClient,
        workspaceID: String,
        hash: String
    ) async {
        defer { workspacePictureFetchInFlight.remove(hash) }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.workspace.picture.get",
                params: [
                    "workspace_id": workspaceID,
                    "hash": hash,
                    "client_id": clientID,
                ]
            )
            let data = try await client.sendRequest(request)
            guard self.remoteClient === client else { return }
            let response = try MobileWorkspacePictureResponse.decode(data)
            guard response.hash == hash, let imageData = response.imageData else { return }
            // Enforce the avatar size contract client-side; treat an oversized
            // response as absent rather than caching attacker-sized blobs.
            guard imageData.count <= Self.maxWorkspacePictureBytes else {
                mobileShellLog.error("workspace picture oversized hash=\(hash, privacy: .public) bytes=\(imageData.count, privacy: .public)")
                return
            }
            cacheWorkspacePicture(imageData, forHash: hash)
            applyCachedWorkspacePictures()
        } catch {
            mobileShellLog.info("workspace picture fetch failed hash=\(hash, privacy: .public) error=\(String(describing: error), privacy: .private)")
        }
    }

    private func cacheWorkspacePicture(_ data: Data, forHash hash: String) {
        if workspacePictureBytesByHash[hash] == nil {
            workspacePictureHashLRU.append(hash)
        }
        workspacePictureBytesByHash[hash] = data
        guard workspacePictureHashLRU.count > Self.maxCachedWorkspacePictures else { return }
        // Single bounded pass, oldest first: evict unreferenced hashes until the
        // cache fits. A hash still referenced by a live workspace is never
        // evicted, so when every cached avatar is live the cache simply stays
        // over budget for this round (bounded by the live workspace count).
        let liveHashes = Set(workspaces.compactMap(\.pictureHash))
        var overflow = workspacePictureHashLRU.count - Self.maxCachedWorkspacePictures
        var retained: [String] = []
        retained.reserveCapacity(workspacePictureHashLRU.count)
        for candidate in workspacePictureHashLRU {
            if overflow > 0, !liveHashes.contains(candidate) {
                workspacePictureBytesByHash.removeValue(forKey: candidate)
                overflow -= 1
            } else {
                retained.append(candidate)
            }
        }
        workspacePictureHashLRU = retained
    }

    /// Re-stamp `pictureData` on each workspace from the cache (after a fetch
    /// resolved new bytes), publishing the change so rows pick up the avatar.
    private func applyCachedWorkspacePictures() {
        var didChange = false
        let updated = workspaces.map { workspace -> MobileWorkspacePreview in
            let resolved = workspace.pictureHash.flatMap { workspacePictureBytesByHash[$0] }
            guard workspace.pictureData != resolved else { return workspace }
            var copy = workspace
            copy.pictureData = resolved
            didChange = true
            return copy
        }
        if didChange {
            workspaces = updated
        }
    }
}
