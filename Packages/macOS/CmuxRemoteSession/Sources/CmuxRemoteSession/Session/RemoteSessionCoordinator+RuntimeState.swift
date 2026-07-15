public import Foundation

extension RemoteSessionCoordinator {
    /// Queues the latest workspace snapshot for the authoritative daemon slot.
    ///
    /// The initial ready transition always fetches first. An existing server
    /// document wins over a snapshot queued before synchronization; an empty
    /// server is seeded from the queued snapshot. Later snapshots use the
    /// umbrella's last-writer-wins control model.
    ///
    /// - Parameters:
    ///   - schemaVersion: Client-owned workspace snapshot schema.
    ///   - state: Workspace snapshot encoded as a JSON object.
    public func enqueueRuntimeState(schemaVersion: Int, state: Data) {
        guard configuration.persistentDaemonSlot != nil else { return }
        let upload = RemoteRuntimeStateUpload(schemaVersion: schemaVersion, state: state)
        queue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            self.pendingRuntimeStateUpload = upload
            self.synchronizeRuntimeStateLocked()
            self.flushPendingRuntimeStateUploadLocked()
        }
    }

    func synchronizeRuntimeStateLocked() {
        guard runtimeStateCapabilityAvailable,
              !runtimeStateSynchronized,
              proxyLease != nil else { return }
        do {
            if let document = try proxyBroker.getRuntimeState(configuration: configuration) {
                runtimeStateSynchronized = true
                pendingRuntimeStateUpload = nil
                host.publishRuntimeState(document)
            } else {
                runtimeStateSynchronized = true
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
        do {
            let document = try proxyBroker.putRuntimeState(
                configuration: configuration,
                schemaVersion: upload.schemaVersion,
                state: upload.state,
                expectedRevision: nil
            )
            guard pendingRuntimeStateUpload?.state == upload.state else { return }
            pendingRuntimeStateUpload = nil
            host.publishRuntimeStateRevision(document.revision)
        } catch {
            debugLog("remote.runtimeState.putFailed error=\(error.localizedDescription)")
        }
    }
}
