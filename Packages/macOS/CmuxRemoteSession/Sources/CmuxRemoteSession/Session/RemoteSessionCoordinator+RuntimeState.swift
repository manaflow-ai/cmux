internal import CmuxRemoteDaemon
public import Foundation

extension RemoteSessionCoordinator {
    /// Queues the latest workspace snapshot for the authoritative daemon slot.
    ///
    /// The initial ready transition always fetches first. An existing server
    /// document wins over a snapshot queued before synchronization; an empty
    /// server is seeded from the queued snapshot. Later snapshots are
    /// conditionally committed against the revision they were derived from.
    ///
    /// - Parameters:
    ///   - schemaVersion: Client-owned workspace snapshot schema.
    ///   - state: Workspace snapshot encoded as a JSON object.
    ///   - baseRevision: Daemon revision the snapshot was derived from. Pass
    ///     `nil` only when the caller does not project daemon revisions.
    public func enqueueRuntimeState(
        schemaVersion: Int,
        state: Data,
        baseRevision: UInt64? = nil
    ) {
        guard configuration.persistentDaemonSlot != nil else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            guard state.count <= RemoteRuntimeStateDocument.maximumStateBytes else {
                self.debugLog("remote.runtimeState.drop reason=oversized bytes=\(state.count)")
                return
            }
            let upload = RemoteRuntimeStateUpload(
                schemaVersion: schemaVersion,
                state: state,
                baseRevision: baseRevision ?? self.lastKnownRuntimeStateRevision
            )
            self.pendingRuntimeStateUpload = upload
            self.synchronizeRuntimeStateLocked()
            self.flushPendingRuntimeStateUploadLocked()
        }
    }

    func synchronizeRuntimeStateLocked() {
        guard runtimeStateCapabilityAvailable,
              !runtimeStateSynchronized,
              proxyLease != nil else { return }
        let isInitialSynchronization = !hasCompletedInitialRuntimeStateSynchronization
        let previousRevision = lastKnownRuntimeStateRevision
        do {
            if let document = try proxyBroker.getRuntimeState(configuration: configuration) {
                runtimeStateSynchronized = true
                hasCompletedInitialRuntimeStateSynchronization = true
                lastKnownRuntimeStateRevision = document.revision
                if isInitialSynchronization {
                    pendingRuntimeStateUpload = nil
                    host.publishRuntimeState(document)
                } else if let pendingRuntimeStateUpload,
                          pendingRuntimeStateUpload.baseRevision == previousRevision,
                          document.revision == previousRevision {
                    // The server has not advanced while this client was offline;
                    // preserve and conditionally commit the local edit.
                } else {
                    pendingRuntimeStateUpload = nil
                    host.publishRuntimeState(document)
                }
                flushPendingRuntimeStateUploadLocked()
            } else {
                runtimeStateSynchronized = true
                hasCompletedInitialRuntimeStateSynchronization = true
                lastKnownRuntimeStateRevision = 0
                flushPendingRuntimeStateUploadLocked()
            }
        } catch {
            debugLog("remote.runtimeState.fetchFailed error=\(error.localizedDescription)")
        }
    }

    func flushPendingRuntimeStateUploadLocked() {
        guard runtimeStateCapabilityAvailable,
              runtimeStateSynchronized,
              proxyLease != nil,
              let upload = pendingRuntimeStateUpload else { return }
        let baseDescription = upload.baseRevision.map(String.init) ?? "unknown"
        guard let baseRevision = upload.baseRevision,
              baseRevision >= lastKnownRuntimeStateRevision else {
            pendingRuntimeStateUpload = nil
            debugLog(
                "remote.runtimeState.drop reason=stale " +
                    "base=\(baseDescription) " +
                    "current=\(lastKnownRuntimeStateRevision)"
            )
            return
        }
        do {
            let document = try proxyBroker.putRuntimeState(
                configuration: configuration,
                schemaVersion: upload.schemaVersion,
                state: upload.state,
                expectedRevision: lastKnownRuntimeStateRevision
            )
            guard pendingRuntimeStateUpload?.state == upload.state else { return }
            pendingRuntimeStateUpload = nil
            lastKnownRuntimeStateRevision = document.revision
            host.publishRuntimeStateRevision(document.revision)
        } catch {
            runtimeStateSynchronized = false
            debugLog("remote.runtimeState.putFailed error=\(error.localizedDescription)")
        }
    }
}
