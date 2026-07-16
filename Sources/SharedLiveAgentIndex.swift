import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex {
    static let shared = SharedLiveAgentIndex()

    private struct ForkProbeKey: Hashable {
        let panelKey: RestorableAgentSessionIndex.PanelKey
        let isRemoteContext: Bool
    }

    private typealias ForkExecutableWatchKey = [String]
    private typealias ForkExecutableWatchRecord = (
        generation: UUID,
        probeKeys: Set<ForkProbeKey>,
        sources: [DispatchSourceFileSystemObject]
    )

    private struct ForkSupportValidation {
        let identity: String
        let refreshBeforeReuse: Bool
        let isSupported: Bool
        let completedAt: Date
        let requiresLiveIndexPanel: Bool
    }

    private typealias ForkValidationRequest = (
        id: UUID,
        fallbackSnapshot: SessionRestorableAgentSnapshot?
    )
    private typealias ForkValidationRequestsByProbeKey = [ForkProbeKey: [ForkValidationRequest]]
    private typealias ForkValidationRequestBatch = (
        probeKey: ForkProbeKey,
        requests: [ForkValidationRequest]
    )

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var forkAvailabilityRefreshTask: Task<Void, Never>?
    private var validatedForkSupport: [ForkProbeKey: ForkSupportValidation] = [:]
    private var forkExecutableWatchRecords: [ForkExecutableWatchKey: ForkExecutableWatchRecord] = [:]
    private var forkExecutableWatchKeysByProbeKey: [ForkProbeKey: ForkExecutableWatchKey] = [:]
    private var forkExecutableWatchGenerations: [ForkProbeKey: UUID] = [:]
    private var validatedForkPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var validatedMissingForkPanels: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var activeForkSupportValidationKeys = Set<ForkProbeKey>()
    private var activeForkSupportValidationWaiters: [ForkProbeKey: [CheckedContinuation<Void, Never>]] = [:]
    private var deferredForkAvailabilityRefreshAfterActiveValidation = false
    private var pendingForkValidationRequests: ForkValidationRequestsByProbeKey = [:]
    private var processingForkValidationRequestIDs: [ForkProbeKey: Set<UUID>] = [:]
    private var cancelledForkValidationRequestIDs: [ForkProbeKey: Set<UUID>] = [:]
    private var processScopeFingerprint: Set<String> = []
    private var changePending = false
    private var deferredReloadTimer: DispatchSourceTimer?

    private static let cacheTTL: TimeInterval = 60.0
    private static let forkAvailabilityProbeTTL: TimeInterval = 15.0
    nonisolated private static let maximumForkExecutableWatchPathCountPerValidation = 32
    nonisolated private static let maximumForkExecutableWatchSourceCount = 256
    // Floor between event-driven reloads so chatty hook stores cannot keep the
    // measured ~350ms-1.8s loader running at near-continuous duty cycle.
    private static let minEventReloadInterval: TimeInterval = 5.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private let indexLoader: @Sendable () -> SharedLiveAgentIndexLoader.LoadResult
    private let forkSupportProvider: @Sendable (SessionRestorableAgentSnapshot, Bool) async -> Bool
    private let hookStoreDirectoryProvider: @MainActor () -> String
    private let dateProvider: @MainActor () -> Date
    private let forkExecutableWatchOpenSuspensionForTesting: @MainActor @Sendable () async -> Void

    init(
        indexLoader: @escaping @Sendable () -> SharedLiveAgentIndexLoader.LoadResult = {
            SharedLiveAgentIndexLoader().loadResultSynchronously()
        },
        forkSupportProvider: @escaping @Sendable (SessionRestorableAgentSnapshot, Bool) async -> Bool = {
            snapshot,
            isRemoteContext in
            await AgentForkSupport.supportsFork(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            )
        },
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        },
        dateProvider: @escaping @MainActor () -> Date = {
            Date()
        },
        forkExecutableWatchOpenSuspensionForTesting: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.indexLoader = indexLoader
        self.forkSupportProvider = { snapshot, isRemoteContext in
            let task = Task.detached(priority: .utility) {
                await forkSupportProvider(snapshot, isRemoteContext)
            }
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
        self.dateProvider = dateProvider
        self.forkExecutableWatchOpenSuspensionForTesting = forkExecutableWatchOpenSuspensionForTesting
    }

    deinit {
        refreshTask?.cancel()
        forkAvailabilityRefreshTask?.cancel()
        deferredReloadTimer?.cancel()
        directoryWatchSource?.cancel()
        for record in forkExecutableWatchRecords.values {
            for source in record.sources {
                source.cancel()
            }
        }
        for waiters in activeForkSupportValidationWaiters.values {
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Read the cached snapshot for stale-tolerant callers. Never blocks.
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        scheduleRefreshIfStale()
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Read the cached snapshot for the Fork Conversation context menu. Never blocks.
    func snapshotForForkConversationCandidate(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let index,
              validatedForkPanelKey(for: panelKey) != nil else {
            return nil
        }
        return index.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    /// Read the cached snapshot for an enabled Fork Conversation action. Never blocks.
    func snapshotForForkAvailability(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false
    ) -> SessionRestorableAgentSnapshot? {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let validationKey = validatedForkPanelKey(for: panelKey),
              let index,
              let snapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId),
              hasFreshForkAvailabilityProbe(
                for: ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext),
                snapshot: snapshot
              ),
              validatedForkSupport[
                ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext)
              ]?.isSupported == true else {
            return nil
        }
        return snapshot
    }

    func forkSupportProbeRejected(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> Bool {
        forkSupportValidation(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteContext,
            fallbackSnapshot: fallbackSnapshot
        )?.isSupported == false
    }

    func forkSupportProbeAccepted(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> Bool {
        forkSupportValidation(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteContext,
            fallbackSnapshot: fallbackSnapshot
        )?.isSupported == true
    }

    private func forkSupportValidation(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool,
        fallbackSnapshot: SessionRestorableAgentSnapshot?
    ) -> ForkSupportValidation? {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let snapshot = fallbackSnapshot ?? index?.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            return nil
        }
        let validationKey = validatedForkPanelKey(for: panelKey) ?? panelKey
        let probeKey = ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext)
        guard hasFreshForkAvailabilityProbe(for: probeKey, snapshot: snapshot) else { return nil }
        return validatedForkSupport[probeKey]
    }

    func prepareForkAvailabilityProbe(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> Bool {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let probeKey = ForkProbeKey(panelKey: panelKey, isRemoteContext: isRemoteContext)
        scheduleRefreshIfStale(validating: panelKey, isRemoteContext: isRemoteContext)
        guard let index else {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
            return false
        }
        guard let snapshot = fallbackSnapshot ?? index.snapshot(workspaceId: workspaceId, panelId: panelId) else {
            if let validatedAt = validatedMissingForkPanels[panelKey],
               dateProvider().timeIntervalSince(validatedAt) < Self.minEventReloadInterval {
                return true
            }
            requestForkAvailabilityRefresh(validating: probeKey)
            return false
        }
        guard let validationKey = validatedForkPanelKey(for: panelKey) ?? (fallbackSnapshot == nil ? nil : panelKey) else {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
            return false
        }
        let resolvedProbeKey = ForkProbeKey(panelKey: validationKey, isRemoteContext: isRemoteContext)
        guard hasFreshForkAvailabilityProbe(for: resolvedProbeKey, snapshot: snapshot) else {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
            return false
        }
        return true
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    func scheduleRefreshIfStale(
        validating panelKey: RestorableAgentSessionIndex.PanelKey? = nil,
        isRemoteContext: Bool = false
    ) {
        ensureWatchingHookStoreDirectory()
        guard refreshTask == nil, forkAvailabilityRefreshTask == nil else {
            if let panelKey {
                insertPendingForkValidation(
                    ForkProbeKey(panelKey: panelKey, isRemoteContext: isRemoteContext)
                )
            }
            return
        }
        if let loadedAt, dateProvider().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return
        }
        if let panelKey {
            insertPendingForkValidation(
                ForkProbeKey(panelKey: panelKey, isRemoteContext: isRemoteContext)
            )
        }
        startReload()
    }

    func refreshForkAvailabilityNow(
        workspaceId: UUID? = nil,
        panelId: UUID? = nil,
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) async {
        var pendingRequestIDsOwnedByRequest: [ForkProbeKey: Set<UUID>] = [:]
        if let workspaceId, let panelId {
            let probeKey = ForkProbeKey(
                panelKey: RestorableAgentSessionIndex.PanelKey(
                    workspaceId: workspaceId,
                    panelId: panelId
                ),
                isRemoteContext: isRemoteContext
            )
            let requestID = insertPendingForkValidation(probeKey, fallbackSnapshot: fallbackSnapshot)
            pendingRequestIDsOwnedByRequest[probeKey, default: []].insert(requestID)
        }
        if fallbackSnapshot != nil {
            await applyPendingForkValidations(
                pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsOwnedByRequest
            )
            return
        }
        _ = await reloadIfLiveAgentProcessFingerprintChanged(
            pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsOwnedByRequest
        )
    }

    private func requestForkAvailabilityRefresh(
        validating probeKey: ForkProbeKey,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) {
        insertPendingForkValidation(probeKey, fallbackSnapshot: fallbackSnapshot)
        guard refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return
        }
        forkAvailabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reloadIfLiveAgentProcessFingerprintChanged()
            self.forkAvailabilityRefreshTask = nil
            self.restartForkAvailabilityRefreshIfPending()
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func startReload() {
        deferredReloadTimer?.cancel()
        deferredReloadTimer = nil
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reload(forcePublish: true)
            self.refreshTask = nil
            self.restartForkAvailabilityRefreshIfPending()
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    @discardableResult
    private func insertPendingForkValidation(
        _ probeKey: ForkProbeKey,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> UUID {
        let requestID = UUID()
        pendingForkValidationRequests[probeKey, default: []].append((
            id: requestID,
            fallbackSnapshot: fallbackSnapshot
        ))
        return requestID
    }

    @discardableResult
    private func removePendingForkValidation(probeKey: ForkProbeKey, requestID: UUID) -> Bool {
        guard var requests = pendingForkValidationRequests[probeKey] else {
            return false
        }
        let originalCount = requests.count
        requests.removeAll { $0.id == requestID }
        let didRemove = requests.count != originalCount
        if requests.isEmpty {
            pendingForkValidationRequests.removeValue(forKey: probeKey)
        } else {
            pendingForkValidationRequests[probeKey] = requests
        }
        return didRemove
    }

    private func markCancelledForkValidationRequests(_ requestIDsByProbeKey: [ForkProbeKey: Set<UUID>]) {
        for (probeKey, requestIDs) in requestIDsByProbeKey where !requestIDs.isEmpty {
            cancelledForkValidationRequestIDs[probeKey, default: []].formUnion(requestIDs)
        }
    }

    private func pruneCancelledForkValidationRequestIDs(
        probeKey: ForkProbeKey,
        retiredRequestIDs: Set<UUID>
    ) {
        guard !retiredRequestIDs.isEmpty,
              var cancelledRequestIDs = cancelledForkValidationRequestIDs[probeKey] else {
            return
        }
        cancelledRequestIDs.subtract(retiredRequestIDs)
        if cancelledRequestIDs.isEmpty {
            cancelledForkValidationRequestIDs.removeValue(forKey: probeKey)
        } else {
            cancelledForkValidationRequestIDs[probeKey] = cancelledRequestIDs
        }
    }

    private func markProcessingForkValidationRequests(_ requestsByProbeKey: ForkValidationRequestsByProbeKey) {
        for (probeKey, requests) in requestsByProbeKey {
            let requestIDs = Set(requests.map(\.id))
            guard !requestIDs.isEmpty else { continue }
            processingForkValidationRequestIDs[probeKey, default: []].formUnion(requestIDs)
        }
    }

    private func retireProcessingForkValidationRequests(
        probeKey: ForkProbeKey,
        requestIDs: Set<UUID>
    ) {
        guard !requestIDs.isEmpty,
              var processingRequestIDs = processingForkValidationRequestIDs[probeKey] else {
            return
        }
        processingRequestIDs.subtract(requestIDs)
        if processingRequestIDs.isEmpty {
            processingForkValidationRequestIDs.removeValue(forKey: probeKey)
        } else {
            processingForkValidationRequestIDs[probeKey] = processingRequestIDs
        }
    }

    private func removeOrMarkCancelledForkValidationRequests(
        _ requestIDsByProbeKey: [ForkProbeKey: Set<UUID>]
    ) {
        var requestIDsToMark: [ForkProbeKey: Set<UUID>] = [:]
        for (probeKey, requestIDs) in requestIDsByProbeKey {
            for requestID in requestIDs {
                if !removePendingForkValidation(probeKey: probeKey, requestID: requestID) {
                    let isStillProcessing = processingForkValidationRequestIDs[probeKey]?.contains(requestID) == true
                    if isStillProcessing {
                        requestIDsToMark[probeKey, default: []].insert(requestID)
                    }
                }
            }
        }
        markCancelledForkValidationRequests(requestIDsToMark)
    }

    private func clearPendingForkValidations() {
        pendingForkValidationRequests.removeAll()
    }

    private func restorePendingForkValidationsAfterCancellation(
        _ pendingRequestsByProbeKey: ForkValidationRequestsByProbeKey,
        dropping requestIDsByProbeKey: [ForkProbeKey: Set<UUID>]
    ) {
        for (probeKey, requests) in pendingRequestsByProbeKey {
            let requestIDs = Set(requests.map(\.id))
            let requestIDsToDrop = (requestIDsByProbeKey[probeKey] ?? [])
                .union(cancelledForkValidationRequestIDs[probeKey] ?? [])
            pruneCancelledForkValidationRequestIDs(
                probeKey: probeKey,
                retiredRequestIDs: requestIDsToDrop
            )
            let requestsToRestore = requests.filter { !requestIDsToDrop.contains($0.id) }
            retireProcessingForkValidationRequests(probeKey: probeKey, requestIDs: requestIDs)
            guard !requestsToRestore.isEmpty else { continue }
            pendingForkValidationRequests[probeKey, default: []].append(contentsOf: requestsToRestore)
        }
        restartForkAvailabilityRefreshIfPending()
    }

    private func restartForkAvailabilityRefreshIfPending() {
        guard !pendingForkValidationRequests.isEmpty,
              refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return
        }
        forkAvailabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reloadIfLiveAgentProcessFingerprintChanged()
            self.forkAvailabilityRefreshTask = nil
            self.restartForkAvailabilityRefreshIfPending()
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func waitForActiveForkSupportValidation(_ probeKey: ForkProbeKey) async {
        await withCheckedContinuation { continuation in
            activeForkSupportValidationWaiters[probeKey, default: []].append(continuation)
        }
    }

    @discardableResult
    private func resumeForkSupportValidationWaiters(for probeKey: ForkProbeKey) -> Bool {
        guard let waiters = activeForkSupportValidationWaiters.removeValue(forKey: probeKey) else {
            return false
        }
        for waiter in waiters {
            waiter.resume()
        }
        return !waiters.isEmpty
    }

    private var pendingForkValidationPanels: Set<ForkProbeKey> {
        Set(pendingForkValidationRequests.keys)
    }

    private func reloadIfLiveAgentProcessFingerprintChanged(
        pendingRequestIDsToRemoveOnCancellation: [ForkProbeKey: Set<UUID>] = [:]
    ) async -> Bool {
        guard refreshTask == nil else {
            changePending = true
            return false
        }
        await reload(
            forcePublish: index == nil,
            pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsToRemoveOnCancellation
        )
        return true
    }

    private func reload(
        forcePublish: Bool,
        pendingRequestIDsToRemoveOnCancellation: [ForkProbeKey: Set<UUID>] = [:]
    ) async {
        let indexLoader = self.indexLoader
        let result = await Task.detached(priority: .utility) {
            indexLoader()
        }.value
        guard !Task.isCancelled else {
            removeOrMarkCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
            return
        }
        let loadedAt = dateProvider()
        let hasPendingForkValidations = !pendingForkValidationPanels.isEmpty
        if forcePublish
            || hasPendingForkValidations
            || result.liveAgentProcessFingerprint != liveAgentProcessFingerprint
            || result.processScopeFingerprint != processScopeFingerprint {
            applyReloadedIndex(
                result.index,
                loadedAt: loadedAt,
                liveAgentProcessFingerprint: result.liveAgentProcessFingerprint,
                processScopeFingerprint: result.processScopeFingerprint,
                forkValidatedPanels: result.forkValidatedPanels
            )
        } else {
            self.loadedAt = loadedAt
            self.processScopeFingerprint = result.processScopeFingerprint
            self.validatedForkPanels = result.forkValidatedPanels
        }
        await applyPendingForkValidations(
            pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsToRemoveOnCancellation
        )
    }

    private func applyReloadedIndex(
        _ newIndex: RestorableAgentSessionIndex,
        loadedAt: Date,
        liveAgentProcessFingerprint: Set<String>,
        processScopeFingerprint: Set<String>,
        forkValidatedPanels: Set<RestorableAgentSessionIndex.PanelKey>
    ) {
        index = newIndex
        self.loadedAt = loadedAt
        validatedForkPanels = forkValidatedPanels
        validatedMissingForkPanels.removeAll()
        pruneForkSupportValidations(validPanelKeys: forkValidatedPanels, now: loadedAt)
        self.liveAgentProcessFingerprint = liveAgentProcessFingerprint
        self.processScopeFingerprint = processScopeFingerprint
    }

    private func applyPendingForkValidations(
        pendingRequestIDsToRemoveOnCancellation: [ForkProbeKey: Set<UUID>] = [:]
    ) async {
        let pendingRequestsByProbeKey = pendingForkValidationRequests
        let pendingRequestBatches = Self.forkValidationRequestBatches(from: pendingRequestsByProbeKey)
        markProcessingForkValidationRequests(pendingRequestsByProbeKey)
        clearPendingForkValidations()
        guard !Task.isCancelled else {
            markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
            restorePendingForkValidationsAfterCancellation(
                pendingRequestsByProbeKey,
                dropping: pendingRequestIDsToRemoveOnCancellation
            )
            return
        }
        for batchIndex in pendingRequestBatches.indices {
            let probeKey = pendingRequestBatches[batchIndex].probeKey
            let pendingRequests = pendingRequestBatches[batchIndex].requests
            let unprocessedRequestsByProbeKey = Self.forkValidationRequestDictionary(
                from: pendingRequestBatches[batchIndex...]
            )
            let pendingRequestIDsForProbe = Set(pendingRequests.map { $0.id })
            var requeuedPendingRequests = false
            defer {
                if !requeuedPendingRequests {
                    retireProcessingForkValidationRequests(
                        probeKey: probeKey,
                        requestIDs: pendingRequestIDsForProbe
                    )
                    pruneCancelledForkValidationRequestIDs(
                        probeKey: probeKey,
                        retiredRequestIDs: pendingRequestIDsForProbe
                    )
                }
            }
            guard !Task.isCancelled else {
                markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                restorePendingForkValidationsAfterCancellation(
                    unprocessedRequestsByProbeKey,
                    dropping: pendingRequestIDsToRemoveOnCancellation
                )
                return
            }
            let cancelledRequestIDsForProbe = cancelledForkValidationRequestIDs[probeKey] ?? []
            pruneCancelledForkValidationRequestIDs(
                probeKey: probeKey,
                retiredRequestIDs: Set(pendingRequests.map { $0.id }).intersection(cancelledRequestIDsForProbe)
            )
            let activeRequests = pendingRequests.filter { !cancelledRequestIDsForProbe.contains($0.id) }
            guard !activeRequests.isEmpty else {
                continue
            }
            let panelKey = probeKey.panelKey
            let fallbackSnapshot = Self.pendingForkValidationFallbackSnapshot(activeRequests)
            if fallbackSnapshot == nil, index == nil {
                pendingForkValidationRequests[probeKey, default: []].append(contentsOf: activeRequests)
                retireProcessingForkValidationRequests(
                    probeKey: probeKey,
                    requestIDs: Set(activeRequests.map(\.id))
                )
                requeuedPendingRequests = true
                continue
            }
            let validationRequiresLiveIndexPanel = fallbackSnapshot == nil
            let snapshot = fallbackSnapshot ?? index?.snapshot(
                workspaceId: panelKey.workspaceId,
                panelId: panelKey.panelId
            )
            if snapshot == nil {
                validatedMissingForkPanels[panelKey] = dateProvider()
            } else if let validationKey = validatedForkPanelKey(for: panelKey)
                        ?? (fallbackSnapshot == nil ? nil : panelKey),
                      let snapshot {
                let resolvedProbeKey = ForkProbeKey(
                    panelKey: validationKey,
                    isRemoteContext: probeKey.isRemoteContext
                )
                guard !activeForkSupportValidationKeys.contains(resolvedProbeKey) else {
                    pendingForkValidationRequests[probeKey, default: []].append(contentsOf: activeRequests)
                    retireProcessingForkValidationRequests(
                        probeKey: probeKey,
                        requestIDs: Set(activeRequests.map(\.id))
                    )
                    requeuedPendingRequests = true
                    deferredForkAvailabilityRefreshAfterActiveValidation = true
                    await waitForActiveForkSupportValidation(resolvedProbeKey)
                    guard !Task.isCancelled else {
                        removeOrMarkCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                        restorePendingForkValidationsAfterCancellation(
                            Self.forkValidationRequestDictionary(from: pendingRequestBatches[(batchIndex + 1)...]),
                            dropping: pendingRequestIDsToRemoveOnCancellation
                        )
                        return
                    }
                    deferredForkAvailabilityRefreshAfterActiveValidation = false
                    await applyPendingForkValidations(
                        pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsToRemoveOnCancellation
                    )
                    return
                }
                activeForkSupportValidationKeys.insert(resolvedProbeKey)
                defer {
                    activeForkSupportValidationKeys.remove(resolvedProbeKey)
                    let resumedWaiters = resumeForkSupportValidationWaiters(for: resolvedProbeKey)
                    if activeForkSupportValidationKeys.isEmpty,
                       deferredForkAvailabilityRefreshAfterActiveValidation,
                       !resumedWaiters {
                        deferredForkAvailabilityRefreshAfterActiveValidation = false
                        restartForkAvailabilityRefreshIfPending()
                    }
                }
                if let identity = AgentForkSupport.forkValidationIdentity(
                    snapshot: snapshot,
                    isRemoteContext: probeKey.isRemoteContext
                ) {
                    let requiresExecutableIdentity = AgentForkSupport.requiresForkValidationExecutableIdentity(
                        snapshot: snapshot,
                        isRemoteContext: probeKey.isRemoteContext
                    )
                    let executableResolutionBeforeProbe: (
                        status: String,
                        lookupPath: String?,
                        realPath: String?,
                        cachePart: String?,
                        watchDirectories: [String]
                    )
                    if requiresExecutableIdentity {
                        executableResolutionBeforeProbe = await Task.detached(priority: .utility) {
                            AgentForkSupport.forkValidationExecutableResolution(
                                snapshot: snapshot,
                                isRemoteContext: probeKey.isRemoteContext
                            )
                        }.value
                        guard !Task.isCancelled else {
                            markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                            removeForkSupportValidation(for: resolvedProbeKey)
                            restorePendingForkValidationsAfterCancellation(
                                unprocessedRequestsByProbeKey,
                                dropping: pendingRequestIDsToRemoveOnCancellation
                            )
                            return
                        }
                    } else {
                        executableResolutionBeforeProbe = ("notRequired", nil, nil, nil, [])
                    }
                    let watchGeneration: UUID?
                    switch executableResolutionBeforeProbe.status {
                    case "notRequired":
                        guard !requiresExecutableIdentity else {
                            removeForkSupportValidation(for: resolvedProbeKey)
                            continue
                        }
                        clearForkExecutableWatch(for: resolvedProbeKey)
                        watchGeneration = nil
                    case "skipRemoteLikeContext":
                        clearForkExecutableWatch(for: resolvedProbeKey)
                        watchGeneration = nil
                    case "unresolved":
                        storeRejectedForkSupportValidation(
                            identity: identity,
                            for: resolvedProbeKey,
                            requiresLiveIndexPanel: validationRequiresLiveIndexPanel,
                            refreshBeforeReuse: true
                        )
                        continue
                    case "resolved":
                        guard let lookupPath = executableResolutionBeforeProbe.lookupPath,
                              let realPath = executableResolutionBeforeProbe.realPath else {
                            removeForkSupportValidation(for: resolvedProbeKey)
                            continue
                        }
                        watchGeneration = await updateForkExecutableWatch(
                            for: resolvedProbeKey,
                            lookupPath: lookupPath,
                            realPath: realPath,
                            watchDirectories: executableResolutionBeforeProbe.watchDirectories
                        )
                        guard !Task.isCancelled else {
                            markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                            removeForkSupportValidation(for: resolvedProbeKey)
                            restorePendingForkValidationsAfterCancellation(
                                unprocessedRequestsByProbeKey,
                                dropping: pendingRequestIDsToRemoveOnCancellation
                            )
                            return
                        }
                        guard watchGeneration != nil else {
                            removeForkSupportValidation(for: resolvedProbeKey)
                            continue
                        }
                    default:
                        removeForkSupportValidation(for: resolvedProbeKey)
                        continue
                    }
                    let isSupported = await forkSupportProvider(
                        snapshot,
                        probeKey.isRemoteContext
                    )
                    guard !Task.isCancelled else {
                        markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                        removeForkSupportValidation(for: resolvedProbeKey)
                        restorePendingForkValidationsAfterCancellation(
                            unprocessedRequestsByProbeKey,
                            dropping: pendingRequestIDsToRemoveOnCancellation
                        )
                        return
                    }
                    if requiresExecutableIdentity {
                        let executableResolutionAfterProbe = await Task.detached(priority: .utility) {
                            AgentForkSupport.forkValidationExecutableResolution(
                                snapshot: snapshot,
                                isRemoteContext: probeKey.isRemoteContext
                            )
                        }.value
                        guard !Task.isCancelled else {
                            markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                            removeForkSupportValidation(for: resolvedProbeKey)
                            restorePendingForkValidationsAfterCancellation(
                                unprocessedRequestsByProbeKey,
                                dropping: pendingRequestIDsToRemoveOnCancellation
                            )
                            return
                        }
                        guard Self.forkExecutableResolutionMatches(
                            executableResolutionAfterProbe,
                            executableResolutionBeforeProbe
                        ) else {
                            removeForkSupportValidation(for: resolvedProbeKey)
                            continue
                        }
                    }
                    if let watchGeneration {
                        guard forkExecutableWatchGenerations[resolvedProbeKey] == watchGeneration else {
                            removeForkSupportValidation(for: resolvedProbeKey)
                            continue
                        }
                    }
                    validatedForkSupport[resolvedProbeKey] = ForkSupportValidation(
                        identity: identity,
                        refreshBeforeReuse: false,
                        isSupported: isSupported,
                        completedAt: dateProvider(),
                        requiresLiveIndexPanel: validationRequiresLiveIndexPanel
                    )
                } else {
                    removeForkSupportValidation(for: resolvedProbeKey)
                }
            }
        }
        if activeForkSupportValidationKeys.isEmpty {
            restartForkAvailabilityRefreshIfPending()
        }
    }

    private static func pendingForkValidationFallbackSnapshot(
        _ requests: [ForkValidationRequest]
    ) -> SessionRestorableAgentSnapshot? {
        for request in requests.reversed() {
            if let fallbackSnapshot = request.fallbackSnapshot {
                return fallbackSnapshot
            }
        }
        return nil
    }

    private static func forkValidationRequestBatches(
        from requestsByProbeKey: ForkValidationRequestsByProbeKey
    ) -> [ForkValidationRequestBatch] {
        requestsByProbeKey.map { probeKey, requests in
            (probeKey: probeKey, requests: requests)
        }.sorted { lhs, rhs in
            forkValidationRequestSortKey(lhs.probeKey) < forkValidationRequestSortKey(rhs.probeKey)
        }
    }

    private static func forkValidationRequestSortKey(_ probeKey: ForkProbeKey) -> String {
        [
            probeKey.panelKey.workspaceId.uuidString,
            probeKey.panelKey.panelId.uuidString,
            String(probeKey.isRemoteContext),
        ].joined(separator: "|")
    }

    private static func forkValidationRequestDictionary(
        from batches: ArraySlice<ForkValidationRequestBatch>
    ) -> ForkValidationRequestsByProbeKey {
        var requestsByProbeKey: ForkValidationRequestsByProbeKey = [:]
        for batch in batches {
            requestsByProbeKey[batch.probeKey, default: []].append(contentsOf: batch.requests)
        }
        return requestsByProbeKey
    }

    private func hasFreshForkAvailabilityProbe(
        for probeKey: ForkProbeKey,
        snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let validation = validatedForkSupport[probeKey] else {
            return false
        }
        guard validation.identity == AgentForkSupport.forkValidationIdentity(
            snapshot: snapshot,
            isRemoteContext: probeKey.isRemoteContext
        ) else {
            removeForkSupportValidation(for: probeKey)
            return false
        }
        if validation.refreshBeforeReuse {
            removeForkSupportValidation(for: probeKey)
            return false
        }
        guard dateProvider().timeIntervalSince(validation.completedAt) < Self.forkAvailabilityProbeTTL else {
            removeForkSupportValidation(for: probeKey)
            return false
        }
        return true
    }

    private func pruneForkSupportValidations(
        validPanelKeys: Set<RestorableAgentSessionIndex.PanelKey>,
        now: Date
    ) {
        pruneExpiredForkSupportValidations(now: now)
        for (probeKey, validation) in validatedForkSupport {
            if validation.requiresLiveIndexPanel && !validPanelKeys.contains(probeKey.panelKey) {
                removeForkSupportValidation(for: probeKey)
            }
        }
    }

    private func pruneExpiredForkSupportValidations(now: Date) {
        let expiredProbeKeys = validatedForkSupport.compactMap { probeKey, validation in
            now.timeIntervalSince(validation.completedAt) >= Self.forkAvailabilityProbeTTL ? probeKey : nil
        }
        for probeKey in expiredProbeKeys {
            removeForkSupportValidation(for: probeKey)
        }
    }

    private func removeForkSupportValidation(for probeKey: ForkProbeKey) {
        validatedForkSupport.removeValue(forKey: probeKey)
        clearForkExecutableWatch(for: probeKey)
    }

    private func storeRejectedForkSupportValidation(
        identity: String,
        for probeKey: ForkProbeKey,
        requiresLiveIndexPanel: Bool,
        refreshBeforeReuse: Bool = false
    ) {
        clearForkExecutableWatch(for: probeKey)
        validatedForkSupport[probeKey] = ForkSupportValidation(
            identity: identity,
            refreshBeforeReuse: refreshBeforeReuse,
            isSupported: false,
            completedAt: dateProvider(),
            requiresLiveIndexPanel: requiresLiveIndexPanel
        )
    }

    private func clearForkExecutableWatch(for probeKey: ForkProbeKey) {
        forkExecutableWatchGenerations.removeValue(forKey: probeKey)
        guard let watchKey = forkExecutableWatchKeysByProbeKey.removeValue(forKey: probeKey),
              var record = forkExecutableWatchRecords[watchKey] else {
            return
        }
        record.probeKeys.remove(probeKey)
        if record.probeKeys.isEmpty {
            removeForkExecutableWatchRecord(for: watchKey)
        } else {
            forkExecutableWatchRecords[watchKey] = record
        }
    }

    private func removeForkExecutableWatchRecord(for watchKey: ForkExecutableWatchKey) {
        guard let record = forkExecutableWatchRecords.removeValue(forKey: watchKey) else {
            return
        }
        for probeKey in record.probeKeys {
            forkExecutableWatchKeysByProbeKey.removeValue(forKey: probeKey)
            forkExecutableWatchGenerations.removeValue(forKey: probeKey)
        }
        for source in record.sources {
            source.cancel()
        }
    }

    private func invalidateForkExecutableWatchRecord(
        for watchKey: ForkExecutableWatchKey,
        generation: UUID
    ) {
        guard let record = forkExecutableWatchRecords[watchKey],
              record.generation == generation else {
            return
        }
        let probeKeys = record.probeKeys
        let panelKeys = Set(probeKeys.map(\.panelKey))
        removeForkExecutableWatchRecord(for: watchKey)
        for probeKey in probeKeys {
            validatedForkSupport.removeValue(forKey: probeKey)
        }
        for panelKey in panelKeys {
            NotificationCenter.default.post(
                name: .sharedLiveAgentIndexDidChange,
                object: self,
                userInfo: [
                    "workspaceId": panelKey.workspaceId,
                    "panelId": panelKey.panelId,
                ]
            )
        }
    }

    private static func forkExecutableResolutionMatches(
        _ lhs: (
            status: String,
            lookupPath: String?,
            realPath: String?,
            cachePart: String?,
            watchDirectories: [String]
        ),
        _ rhs: (
            status: String,
            lookupPath: String?,
            realPath: String?,
            cachePart: String?,
            watchDirectories: [String]
        )
    ) -> Bool {
        switch (lhs.status, rhs.status) {
        case ("notRequired", "notRequired"),
             ("skipRemoteLikeContext", "skipRemoteLikeContext"):
            return true
        case ("resolved", "resolved"):
            return lhs.cachePart == rhs.cachePart
        default:
            return false
        }
    }

    private func updateForkExecutableWatch(
        for probeKey: ForkProbeKey,
        lookupPath: String?,
        realPath: String?,
        watchDirectories: [String]
    ) async -> UUID? {
        clearForkExecutableWatch(for: probeKey)
        guard let lookupPath, let realPath else { return nil }
        let resolvedWatchPaths = await Task.detached(priority: .utility) {
            Self.forkExecutableWatchPaths(
                lookupPath: lookupPath,
                realPath: realPath,
                watchDirectories: watchDirectories
            )
        }.value
        guard let watchPaths = resolvedWatchPaths else {
            return nil
        }
        let watchKey: ForkExecutableWatchKey = watchPaths
        if var record = forkExecutableWatchRecords[watchKey] {
            record.probeKeys.insert(probeKey)
            forkExecutableWatchRecords[watchKey] = record
            forkExecutableWatchKeysByProbeKey[probeKey] = watchKey
            forkExecutableWatchGenerations[probeKey] = record.generation
            return record.generation
        }

        await forkExecutableWatchOpenSuspensionForTesting()
        let generation = UUID()
        let openedFileDescriptors = await Task.detached(priority: .utility) {
            Self.openForkExecutableWatchFileDescriptors(watchPaths: watchPaths)
        }.value
        guard let openedFileDescriptors else {
            return nil
        }
        pruneExpiredForkSupportValidations(now: dateProvider())
        if var record = forkExecutableWatchRecords[watchKey] {
            openedFileDescriptors.forEach { Darwin.close($0) }
            record.probeKeys.insert(probeKey)
            forkExecutableWatchRecords[watchKey] = record
            forkExecutableWatchKeysByProbeKey[probeKey] = watchKey
            forkExecutableWatchGenerations[probeKey] = record.generation
            return record.generation
        }
        let activeWatchCount = forkExecutableWatchRecords.values.reduce(0) { partial, record in
            partial + record.sources.count
        }
        guard activeWatchCount + openedFileDescriptors.count <= Self.maximumForkExecutableWatchSourceCount else {
            openedFileDescriptors.forEach { Darwin.close($0) }
            return nil
        }

        var sources: [DispatchSourceFileSystemObject] = []
        for fileDescriptor in openedFileDescriptors {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .delete, .rename, .revoke, .extend, .attrib, .link],
                queue: watchQueue
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.invalidateForkExecutableWatchRecord(
                        for: watchKey,
                        generation: generation
                    )
                }
            }
            source.setCancelHandler {
                Darwin.close(fileDescriptor)
            }
            sources.append(source)
        }
        forkExecutableWatchRecords[watchKey] = (
            generation: generation,
            probeKeys: [probeKey],
            sources: sources
        )
        forkExecutableWatchKeysByProbeKey[probeKey] = watchKey
        forkExecutableWatchGenerations[probeKey] = generation
        for source in sources {
            source.resume()
        }
        return generation
    }

    nonisolated private static func forkExecutableWatchPaths(
        lookupPath: String,
        realPath: String,
        watchDirectories: [String]
    ) -> [String]? {
        var watchPaths = Set<String>()
        watchPaths.insert(realPath)
        let lookupDirectory = URL(fileURLWithPath: lookupPath).deletingLastPathComponent().path
        watchPaths.insert(lookupDirectory)
        guard insertForkExecutableSymlinkRetargetWatchPaths(
            forPath: lookupDirectory,
            into: &watchPaths
        ) else {
            return nil
        }
        for watchDirectory in watchDirectories {
            guard let watchPath = watchableDirectoryPath(forDirectoryPath: watchDirectory) else {
                return nil
            }
            watchPaths.insert(watchPath)
            guard insertForkExecutableSymlinkRetargetWatchPaths(
                forPath: watchDirectory,
                into: &watchPaths
            ) else {
                return nil
            }
        }
        guard watchPaths.count <= maximumForkExecutableWatchPathCountPerValidation else {
            return nil
        }

        return watchPaths.sorted()
    }

    nonisolated private static func openForkExecutableWatchFileDescriptors(
        watchPaths: [String]
    ) -> [Int32]? {
        var openedFileDescriptors: [Int32] = []
        for watchPath in watchPaths {
            let fileDescriptor = Darwin.open(watchPath, O_EVTONLY)
            guard fileDescriptor >= 0 else {
                openedFileDescriptors.forEach { Darwin.close($0) }
                return nil
            }
            openedFileDescriptors.append(fileDescriptor)
        }
        return openedFileDescriptors
    }

    nonisolated private static func insertForkExecutableSymlinkRetargetWatchPaths(
        forPath path: String,
        into watchPaths: inout Set<String>
    ) -> Bool {
        guard let symlinkParentPaths = symlinkParentWatchPaths(forPath: path) else {
            return false
        }
        for symlinkParentPath in symlinkParentPaths {
            guard let watchPath = watchableDirectoryPath(forDirectoryPath: symlinkParentPath) else {
                return false
            }
            watchPaths.insert(watchPath)
        }
        return true
    }

    nonisolated private static func symlinkParentWatchPaths(forPath path: String) -> Set<String>? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.first == "/" else { return [] }
        var watchPaths = Set<String>()
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            let candidate = current.appendingPathComponent(component)
            var status = stat()
            let result = candidate.path.withCString { pointer in
                Darwin.lstat(pointer, &status)
            }
            if result == 0,
               (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                watchPaths.insert(current.path)
            } else if result != 0,
                      errno != ENOENT,
                      errno != ENOTDIR {
                return nil
            }
            current = candidate
        }
        return watchPaths
    }

    nonisolated private static func watchableDirectoryPath(forDirectoryPath path: String) -> String? {
        let fileManager = FileManager.default
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
    }

    private func validatedForkPanelKey(
        for panelKey: RestorableAgentSessionIndex.PanelKey
    ) -> RestorableAgentSessionIndex.PanelKey? {
        if validatedForkPanels.contains(panelKey) {
            return panelKey
        }
        return validatedForkPanels.first { $0.panelId == panelKey.panelId }
    }

    private var isForkAvailabilityRefreshInFlight: Bool {
        refreshTask != nil || forkAvailabilityRefreshTask != nil
    }

    private func handleHookStoreChange() {
        if refreshTask != nil || forkAvailabilityRefreshTask != nil {
            changePending = true
            return
        }
        let elapsed = loadedAt.map { dateProvider().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minEventReloadInterval {
            startReload()
        } else if deferredReloadTimer == nil {
            // DispatchSourceTimer coalesces hook-store event bursts without Task.sleep in runtime code.
            let timer = DispatchSource.makeTimerSource(queue: watchQueue)
            timer.schedule(deadline: .now() + (Self.minEventReloadInterval - elapsed))
            timer.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.deferredReloadTimer?.cancel()
                    self.deferredReloadTimer = nil
                    self.handleHookStoreChange()
                }
            }
            deferredReloadTimer = timer
            timer.resume()
        }
    }

    private func ensureWatchingHookStoreDirectory() {
        guard directoryWatchSource == nil else { return }
        let dir = hookStoreDirectoryProvider()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            return
        }
        // DispatchSource is the platform file-watch bridge; events re-enter MainActor.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleHookStoreChange() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        directoryWatchSource = source
        if refreshTask == nil {
            startReload()
        } else {
            changePending = true
        }
    }
}

extension Notification.Name {
    static let sharedLiveAgentIndexDidChange = Notification.Name("cmux.sharedLiveAgentIndexDidChange")
}
