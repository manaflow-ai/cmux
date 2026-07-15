internal import CmuxRemoteDaemon
public import Foundation

private enum RuntimeStateFetchResult: Sendable {
    case success(RemoteRuntimeStateDocument?)
    case failure(String)
}

private enum RuntimeStatePutResult: Sendable {
    case success(RemoteRuntimeStateDocument)
    case failure(String)
}

extension RemoteSessionCoordinator {
    private static let maximumRuntimeStateRetryCount = 5

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
            if self.runtimeStateRetrySuspended {
                self.cancelRuntimeStateRetryLocked(resetCount: true)
            }
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
              runtimeStateRPCTask == nil,
              runtimeStatePublicationTask == nil,
              proxyLease != nil else { return }
        cancelRuntimeStateRetryLocked(resetCount: false)
        let isInitialSynchronization = !hasCompletedInitialRuntimeStateSynchronization
        let previousRevision = lastKnownRuntimeStateRevision
        beginRuntimeStateFetchLocked(
            isInitialSynchronization: isInitialSynchronization,
            previousRevision: previousRevision
        )
    }

    func flushPendingRuntimeStateUploadLocked() {
        guard runtimeStateCapabilityAvailable,
              runtimeStateSynchronized,
              runtimeStateRPCTask == nil,
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
        beginRuntimeStatePutLocked(upload)
    }

    private func beginRuntimeStateFetchLocked(
        isInitialSynchronization: Bool,
        previousRevision: UInt64
    ) {
        precondition(runtimeStateRPCTask == nil)
        runtimeStateRPCGeneration &+= 1
        let generation = runtimeStateRPCGeneration
        let leaseGeneration = proxyLeaseGeneration
        let proxyBroker = proxyBroker
        let configuration = configuration
        runtimeStateUploadInFlight = nil
        runtimeStateRPCTask = Task { [weak self] in
            let result: RuntimeStateFetchResult = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: .success(
                            try proxyBroker.getRuntimeState(configuration: configuration)
                        ))
                    } catch {
                        continuation.resume(returning: .failure(error.localizedDescription))
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                guard let self,
                      !self.isStopping,
                      self.runtimeStateCapabilityAvailable,
                      self.proxyLease != nil,
                      self.proxyLeaseGeneration == leaseGeneration,
                      self.runtimeStateRPCGeneration == generation else { return }
                self.runtimeStateRPCTask = nil
                self.runtimeStateUploadInFlight = nil
                switch result {
                case .success(let document):
                    self.handleRuntimeStateFetchSuccessLocked(
                        document,
                        isInitialSynchronization: isInitialSynchronization,
                        previousRevision: previousRevision
                    )
                case .failure(let detail):
                    self.runtimeStateSynchronized = false
                    self.debugLog("remote.runtimeState.fetchFailed error=\(detail)")
                    self.scheduleRuntimeStateRetryLocked(reason: "fetchFailed")
                }
            }
        }
    }

    private func handleRuntimeStateFetchSuccessLocked(
        _ document: RemoteRuntimeStateDocument?,
        isInitialSynchronization: Bool,
        previousRevision: UInt64
    ) {
        guard let document else {
            lastKnownRuntimeStateRevision = 0
            publishRuntimeStateRevisionToHostLocked(
                0,
                completesSynchronization: true
            )
            return
        }
        pendingAuthoritativeRuntimeStateDocument = nil
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
    }

    private func beginRuntimeStatePutLocked(_ upload: RemoteRuntimeStateUpload) {
        precondition(runtimeStateRPCTask == nil)
        runtimeStateRPCGeneration &+= 1
        let generation = runtimeStateRPCGeneration
        let leaseGeneration = proxyLeaseGeneration
        let expectedRevision = lastKnownRuntimeStateRevision
        let proxyBroker = proxyBroker
        let configuration = configuration
        runtimeStateUploadInFlight = upload
        runtimeStateRPCTask = Task { [weak self] in
            let result: RuntimeStatePutResult = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: .success(
                            try proxyBroker.putRuntimeState(
                                configuration: configuration,
                                schemaVersion: upload.schemaVersion,
                                state: upload.state,
                                expectedRevision: expectedRevision
                            )
                        ))
                    } catch {
                        continuation.resume(returning: .failure(error.localizedDescription))
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                guard let self,
                      !self.isStopping,
                      self.runtimeStateCapabilityAvailable,
                      self.proxyLease != nil,
                      self.proxyLeaseGeneration == leaseGeneration,
                      self.runtimeStateRPCGeneration == generation else { return }
                self.runtimeStateRPCTask = nil
                self.runtimeStateUploadInFlight = nil
                switch result {
                case .success(let document):
                    if let pendingUpload = self.pendingRuntimeStateUpload,
                       pendingUpload.schemaVersion == upload.schemaVersion,
                       pendingUpload.state == upload.state,
                       pendingUpload.baseRevision == upload.baseRevision {
                        self.pendingRuntimeStateUpload = nil
                    }
                    self.lastKnownRuntimeStateRevision = document.revision
                    self.publishRuntimeStateRevisionToHostLocked(
                        document.revision,
                        rebasingPendingFrom: upload.baseRevision
                    )
                case .failure(let detail):
                    self.runtimeStateSynchronized = false
                    self.debugLog("remote.runtimeState.putFailed error=\(detail)")
                    self.scheduleRuntimeStateRetryLocked(reason: "putFailed")
                }
            }
        }
    }

    func handleRuntimeStateDocumentLocked(
        _ document: RemoteRuntimeStateDocument,
        leaseGeneration: UInt64
    ) {
        guard !isStopping,
              runtimeStateCapabilityAvailable,
              proxyLease != nil,
              proxyLeaseGeneration == leaseGeneration,
              document.revision > lastKnownRuntimeStateRevision else { return }
        if let upload = runtimeStateUploadInFlight,
           document.revision - lastKnownRuntimeStateRevision == 1,
           document.schemaVersion == upload.schemaVersion,
           document.state == upload.state {
            debugLog("remote.runtimeState.ignore reason=localPutEcho revision=\(document.revision)")
            return
        }
        cancelRuntimeStateRPCLocked()
        cancelRuntimeStateRetryLocked(resetCount: false)
        pendingRuntimeStateUpload = nil
        runtimeStateSynchronized = false
        lastKnownRuntimeStateRevision = document.revision
        guard runtimeStatePublicationTask == nil else {
            if pendingAuthoritativeRuntimeStateDocument?.revision ?? 0 < document.revision {
                pendingAuthoritativeRuntimeStateDocument = document
            }
            debugLog("remote.runtimeState.defer reason=newerServerRevision revision=\(document.revision)")
            return
        }
        publishRuntimeStateToHostLocked(document)
    }

    func cancelRuntimeStatePublicationLocked() {
        runtimeStatePublicationGeneration &+= 1
        runtimeStatePublicationTask?.cancel()
        runtimeStatePublicationTask = nil
    }

    func cancelRuntimeStateRPCLocked() {
        runtimeStateRPCGeneration &+= 1
        runtimeStateRPCTask?.cancel()
        runtimeStateRPCTask = nil
        runtimeStateUploadInFlight = nil
    }

    func cancelRuntimeStateRetryLocked(resetCount: Bool) {
        runtimeStateRetryTask?.cancel()
        runtimeStateRetryTask = nil
        runtimeStateRetryToken = nil
        if resetCount {
            runtimeStateRetryCount = 0
            runtimeStateRetrySuspended = false
        }
    }

    private func scheduleRuntimeStateRetryLocked(reason: String) {
        guard !isStopping,
              runtimeStateCapabilityAvailable,
              proxyLease != nil,
              runtimeStateRetryTask == nil,
              !runtimeStateRetrySuspended else { return }
        guard runtimeStateRetryCount < Self.maximumRuntimeStateRetryCount else {
            runtimeStateRetrySuspended = true
            debugLog(
                "remote.runtimeState.retrySuspended reason=\(reason) " +
                    "attempts=\(runtimeStateRetryCount)"
            )
            return
        }
        runtimeStateRetryCount += 1
        let delayMilliseconds = Self.runtimeStateRetryDelayMilliseconds(
            retry: runtimeStateRetryCount
        )
        let token = UUID()
        runtimeStateRetryToken = token
        debugLog(
            "remote.runtimeState.retry reason=\(reason) " +
                "attempt=\(runtimeStateRetryCount) delayMs=\(delayMilliseconds)"
        )
        runtimeStateRetryTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.clock.sleep(forMilliseconds: delayMilliseconds)) != nil else { return }
            self.queue.async {
                self.runtimeStateRetryDelayElapsed(token: token)
            }
        }
    }

    private func runtimeStateRetryDelayElapsed(token: UUID) {
        guard runtimeStateRetryToken == token else { return }
        runtimeStateRetryTask = nil
        runtimeStateRetryToken = nil
        synchronizeRuntimeStateLocked()
    }

    private static func runtimeStateRetryDelayMilliseconds(retry: Int) -> Int {
        let exponent = min(max(0, retry - 1), 4)
        return min(500 << exponent, 8_000)
    }

    private func completeRuntimeStateSynchronizationLocked() {
        runtimeStateSynchronized = true
        hasCompletedInitialRuntimeStateSynchronization = true
        flushPendingRuntimeStateUploadLocked()
        if runtimeStateSynchronized,
           runtimeStatePublicationTask == nil,
           pendingRuntimeStateUpload == nil {
            cancelRuntimeStateRetryLocked(resetCount: true)
        }
    }

    @discardableResult
    private func publishPendingAuthoritativeRuntimeStateDocumentLocked() -> Bool {
        guard runtimeStatePublicationTask == nil,
              let document = pendingAuthoritativeRuntimeStateDocument else { return false }
        pendingAuthoritativeRuntimeStateDocument = nil
        publishRuntimeStateToHostLocked(document)
        return true
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
                    if self.publishPendingAuthoritativeRuntimeStateDocumentLocked() {
                        return
                    }
                    self.cancelRuntimeStateRetryLocked(resetCount: true)
                    return
                }
                if self.publishPendingAuthoritativeRuntimeStateDocumentLocked() {
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
                    if self.publishPendingAuthoritativeRuntimeStateDocumentLocked() {
                        return
                    }
                    self.cancelRuntimeStateRetryLocked(resetCount: true)
                    return
                }
                if self.publishPendingAuthoritativeRuntimeStateDocumentLocked() {
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
                    if self.runtimeStateSynchronized,
                       self.runtimeStatePublicationTask == nil,
                       self.pendingRuntimeStateUpload == nil {
                        self.cancelRuntimeStateRetryLocked(resetCount: true)
                    }
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
