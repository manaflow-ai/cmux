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
            guard self.runtimeStatePublicationTask == nil else {
                self.debugLog("remote.runtimeState.defer reason=awaitingHostPublication")
                return
            }
            self.synchronizeRuntimeStateLocked()
            self.flushPendingRuntimeStateUploadLocked()
        }
    }

    func synchronizeRuntimeStateLocked() {
        guard runtimeStateCapabilityAvailable,
              !runtimeStateSynchronized,
              runtimeStatePublicationTask == nil,
              proxyLease != nil else { return }
        let isInitialSynchronization = !hasCompletedInitialRuntimeStateSynchronization
        let previousRevision = lastKnownRuntimeStateRevision
        do {
            if let document = try proxyBroker.getRuntimeState(configuration: configuration) {
                lastKnownRuntimeStateRevision = document.revision
                if isInitialSynchronization {
                    pendingRuntimeStateUpload = nil
                    publishRuntimeStateToHostLocked(document)
                } else if let pendingRuntimeStateUpload,
                          pendingRuntimeStateUpload.baseRevision == previousRevision,
                          document.revision == previousRevision {
                    // The server has not advanced while this client was offline;
                    // preserve and conditionally commit the local edit.
                    completeRuntimeStateSynchronizationLocked()
                } else {
                    pendingRuntimeStateUpload = nil
                    publishRuntimeStateToHostLocked(document)
                }
            } else {
                lastKnownRuntimeStateRevision = 0
                publishRuntimeStateRevisionToHostLocked(
                    0,
                    completesSynchronization: true
                )
            }
        } catch {
            debugLog("remote.runtimeState.fetchFailed error=\(error.localizedDescription)")
        }
    }

    func flushPendingRuntimeStateUploadLocked() {
        guard runtimeStateCapabilityAvailable,
              runtimeStateSynchronized,
              runtimeStatePublicationTask == nil,
              proxyLease != nil,
              let upload = pendingRuntimeStateUpload else { return }
        let baseDescription = upload.baseRevision.map(String.init) ?? "unknown"
        guard let baseRevision = upload.baseRevision,
              baseRevision == lastKnownRuntimeStateRevision else {
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
            publishRuntimeStateRevisionToHostLocked(
                document.revision,
                rebasingPendingFrom: upload.baseRevision
            )
        } catch {
            runtimeStateSynchronized = false
            debugLog("remote.runtimeState.putFailed error=\(error.localizedDescription)")
        }
    }

    func cancelRuntimeStatePublicationLocked() {
        runtimeStatePublicationGeneration &+= 1
        runtimeStatePublicationTask?.cancel()
        runtimeStatePublicationTask = nil
    }

    private func completeRuntimeStateSynchronizationLocked() {
        runtimeStateSynchronized = true
        hasCompletedInitialRuntimeStateSynchronization = true
        flushPendingRuntimeStateUploadLocked()
    }

    private func publishRuntimeStateToHostLocked(_ document: RemoteRuntimeStateDocument) {
        let generation = beginRuntimeStatePublicationLocked()
        let leaseGeneration = proxyLeaseGeneration
        let host = host
        runtimeStatePublicationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let accepted = await host.publishRuntimeState(document)
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                guard let self,
                      !self.isStopping,
                      self.proxyLease != nil,
                      self.proxyLeaseGeneration == leaseGeneration,
                      self.runtimeStatePublicationGeneration == generation else { return }
                self.runtimeStatePublicationTask = nil
                guard accepted else {
                    self.runtimeStateSynchronized = false
                    self.debugLog("remote.runtimeState.publishRejected kind=document")
                    return
                }
                self.completeRuntimeStateSynchronizationLocked()
            }
        }
    }

    private func publishRuntimeStateRevisionToHostLocked(
        _ revision: UInt64,
        completesSynchronization: Bool = false,
        rebasingPendingFrom previousRevision: UInt64? = nil
    ) {
        let generation = beginRuntimeStatePublicationLocked()
        let leaseGeneration = proxyLeaseGeneration
        let host = host
        runtimeStatePublicationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let accepted = await host.publishRuntimeStateRevision(revision)
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                guard let self,
                      !self.isStopping,
                      self.proxyLease != nil,
                      self.proxyLeaseGeneration == leaseGeneration,
                      self.runtimeStatePublicationGeneration == generation else { return }
                self.runtimeStatePublicationTask = nil
                guard accepted else {
                    self.runtimeStateSynchronized = false
                    self.debugLog("remote.runtimeState.publishRejected kind=revision")
                    return
                }
                if let previousRevision,
                   let pendingUpload = self.pendingRuntimeStateUpload,
                   pendingUpload.baseRevision == previousRevision {
                    self.pendingRuntimeStateUpload = RemoteRuntimeStateUpload(
                        schemaVersion: pendingUpload.schemaVersion,
                        state: pendingUpload.state,
                        baseRevision: revision
                    )
                }
                if completesSynchronization {
                    self.completeRuntimeStateSynchronizationLocked()
                } else {
                    self.flushPendingRuntimeStateUploadLocked()
                }
            }
        }
    }

    private func beginRuntimeStatePublicationLocked() -> UInt64 {
        precondition(runtimeStatePublicationTask == nil)
        runtimeStatePublicationGeneration &+= 1
        return runtimeStatePublicationGeneration
    }
}
