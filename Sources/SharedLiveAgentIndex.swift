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

    private typealias ForkValidationWaitKey = String
    private typealias ForkExecutableWatchKey = [String]
    private typealias ForkExecutableWatchRecord = (
        generation: UUID,
        probeKeys: Set<ForkProbeKey>,
        panelAliasesByProbeKey: [ForkProbeKey: Set<RestorableAgentSessionIndex.PanelKey>],
        sources: [DispatchSourceFileSystemObject]
    )

    private struct ForkSupportValidation {
        let identity: String
        let executableFingerprint: String?
        let refreshBeforeReuse: Bool
        let isSupported: Bool
        let completedAt: Date
        let requiresLiveIndexPanel: Bool
    }

    private typealias ForkValidationRequest = (
        id: UUID,
        identity: String,
        fallbackSnapshot: SessionRestorableAgentSnapshot?
    )
    private typealias ForkValidationRequestsByProbeKey = [ForkProbeKey: [ForkValidationRequest]]
    private typealias ForkValidationRequestBatch = (
        probeKey: ForkProbeKey,
        requests: [ForkValidationRequest]
    )
    private typealias ForkValidationInsertion = (
        requestID: UUID?,
        activeWaitKey: ForkValidationWaitKey?,
        pendingWaitProbeKey: ForkProbeKey?,
        pendingWaitRequestID: UUID?,
        isFreshValidation: Bool
    )
    private typealias ForkValidationIdentityWaiter = (
        id: UUID,
        continuation: CheckedContinuation<Void, Never>
    )
    private typealias ForkValidationRequestCompletionWaiter = (
        id: UUID,
        continuation: CheckedContinuation<Void, Never>
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
    private var pendingForkExecutableWatchDescriptorReservations = 0
    private var forkExecutableWatchPathTasks: [String: Task<ForkExecutableWatchKey?, Never>] = [:]
    private var forkExecutableWatchOpenTasks: [String: Task<[Int32]?, Never>] = [:]
    private var timedOutForkExecutableWatchPathKeys = Set<String>()
    private var timedOutForkExecutableWatchOpenKeys = Set<String>()
    private var validatedForkPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var validatedMissingForkPanels: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var activeForkSupportValidationKeys = Set<ForkProbeKey>()
    private var activeForkSupportValidationWaiters: [ForkProbeKey: [CheckedContinuation<Void, Never>]] = [:]
    private var activeForkSupportValidationIdentityWaiters: [ForkValidationWaitKey: [ForkValidationIdentityWaiter]] = [:]
    private var forkValidationRequestCompletionWaiters: [UUID: [ForkValidationRequestCompletionWaiter]] = [:]
    private var deferredForkAvailabilityRefreshAfterActiveValidation = false
    private var pendingForkValidationRequests: ForkValidationRequestsByProbeKey = [:]
    private var processingForkValidationRequestIDs: [ForkProbeKey: Set<UUID>] = [:]
    private var cancelledForkValidationRequestIDs: [ForkProbeKey: Set<UUID>] = [:]
    private var activeForkSupportValidationRequestIdentities: [ForkProbeKey: Set<String>] = [:]
    private var processScopeFingerprint: Set<String> = []
    private var changePending = false
    private var deferredReloadTimer: DispatchSourceTimer?
    private var forkSupportValidationExpiryTimer: DispatchSourceTimer?

    private static let cacheTTL: TimeInterval = 60.0
    private static let forkAvailabilityProbeTTL: TimeInterval = 15.0
    nonisolated private static let maximumForkExecutableWatchPathCountPerValidation = 32
    nonisolated static let forkExecutableWatchOpenFlags = O_EVTONLY | O_CLOEXEC
    nonisolated private static let maximumForkExecutableWatchSourceCountCeiling = 64
    nonisolated private static let forkExecutableWatchInstallTimeoutNanoseconds: UInt64 = 3_000_000_000
    nonisolated private static let maximumOutstandingForkExecutableWatchInstallWork = 8
    nonisolated private static let minimumReservedFileDescriptorCount = 128
    nonisolated private static let rlimInfinity = rlim_t(Int64.max)
    // Floor between event-driven reloads so chatty hook stores cannot keep the
    // measured ~350ms-1.8s loader running at near-continuous duty cycle.
    private static let minEventReloadInterval: TimeInterval = 5.0

    nonisolated static func forkExecutableWatchSourceCountBudget(
        softFileDescriptorLimit explicitSoftLimit: Int? = nil,
        openFileDescriptorCount explicitOpenFileDescriptorCount: Int? = nil,
        pendingReservationCount: Int = 0
    ) -> Int {
        guard let softLimit = forkExecutableWatchSoftFileDescriptorLimit(explicitSoftLimit),
              let openFileDescriptorCount = explicitOpenFileDescriptorCount ?? currentOpenFileDescriptorCount() else {
            return 0
        }
        let availableAfterReserve = forkExecutableWatchAvailableDescriptorCount(
            softFileDescriptorLimit: softLimit,
            openFileDescriptorCount: openFileDescriptorCount,
            pendingReservationCount: pendingReservationCount
        )
        guard availableAfterReserve > 0 else {
            return 0
        }
        let derivedBudget = max(1, availableAfterReserve / 4)
        return min(maximumForkExecutableWatchSourceCountCeiling, derivedBudget)
    }

    nonisolated private static func forkExecutableWatchDescriptorReserveIsSatisfied(
        pendingReservationCount: Int,
        softFileDescriptorLimit explicitSoftLimit: Int? = nil,
        openFileDescriptorCount explicitOpenFileDescriptorCount: Int? = nil
    ) -> Bool {
        guard let softLimit = forkExecutableWatchSoftFileDescriptorLimit(explicitSoftLimit),
              let openFileDescriptorCount = explicitOpenFileDescriptorCount ?? currentOpenFileDescriptorCount() else {
            return false
        }
        return forkExecutableWatchAvailableDescriptorCount(
            softFileDescriptorLimit: softLimit,
            openFileDescriptorCount: openFileDescriptorCount,
            pendingReservationCount: pendingReservationCount
        ) >= 0
    }

    nonisolated private static func forkExecutableWatchAvailableDescriptorCount(
        softFileDescriptorLimit: Int,
        openFileDescriptorCount: Int,
        pendingReservationCount: Int
    ) -> Int {
        softFileDescriptorLimit
            - openFileDescriptorCount
            - pendingReservationCount
            - minimumReservedFileDescriptorCount
    }

    nonisolated private static func forkExecutableWatchSoftFileDescriptorLimit(
        _ explicitSoftLimit: Int?
    ) -> Int? {
        if let explicitSoftLimit {
            return explicitSoftLimit
        }
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0,
              limit.rlim_cur != rlimInfinity,
              limit.rlim_cur <= rlim_t(Int.max) else {
            return nil
        }
        return Int(limit.rlim_cur)
    }

    nonisolated private static func currentOpenFileDescriptorCount() -> Int? {
        guard let fileDescriptorNames = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return nil
        }
        return fileDescriptorNames.compactMap(Int.init).count
    }

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private let indexLoader: @Sendable () -> SharedLiveAgentIndexLoader.LoadResult
    private let forkExecutableIdentityResolver: AgentForkExecutableIdentityResolver
    private let forkCapabilityProbeCache: ForkCapabilityProbeResultCache
    private let customForkSupportProvider: (@Sendable (SessionRestorableAgentSnapshot, Bool) async -> Bool)?
    private let hookStoreDirectoryProvider: @MainActor () -> String
    private let dateProvider: @MainActor () -> Date
    private let forkExecutableWatchSourceBudgetProvider: @MainActor (Int) -> Int

    init(
        indexLoader: @escaping @Sendable () -> SharedLiveAgentIndexLoader.LoadResult = {
            SharedLiveAgentIndexLoader().loadResultSynchronously()
        },
        forkExecutableIdentityResolver: AgentForkExecutableIdentityResolver = AgentForkExecutableIdentityResolver(),
        forkCapabilityProbeCache: ForkCapabilityProbeResultCache = ForkCapabilityProbeResultCache(),
        forkSupportProvider: (@Sendable (SessionRestorableAgentSnapshot, Bool) async -> Bool)? = nil,
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        },
        dateProvider: @escaping @MainActor () -> Date = {
            Date()
        },
        forkExecutableWatchSourceBudgetProvider: @escaping @MainActor (Int) -> Int = { pendingReservationCount in
            SharedLiveAgentIndex.forkExecutableWatchSourceCountBudget(
                pendingReservationCount: pendingReservationCount
            )
        }
    ) {
        self.indexLoader = indexLoader
        self.forkExecutableIdentityResolver = forkExecutableIdentityResolver
        self.forkCapabilityProbeCache = forkCapabilityProbeCache
        self.customForkSupportProvider = forkSupportProvider
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
        self.dateProvider = dateProvider
        self.forkExecutableWatchSourceBudgetProvider = forkExecutableWatchSourceBudgetProvider
    }

    func forkValidationExecutableFingerprint(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) async -> String {
        let executableResolution = await forkValidationExecutableResolution(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        )
        return AgentForkSupport.forkValidationExecutableFingerprint(executableResolution)
    }

    private func forkValidationExecutableResolution(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) async -> AgentForkSupport.ForkValidationExecutableResolution {
        await forkExecutableIdentityResolver.validationExecutableResolution(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        )
    }

    private func supportsFork(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool
    ) async -> Bool {
        let customForkSupportProvider = customForkSupportProvider
        let forkExecutableIdentityResolver = forkExecutableIdentityResolver
        let forkCapabilityProbeCache = forkCapabilityProbeCache
        let task = Task.detached(priority: .utility) {
            if let customForkSupportProvider {
                return await customForkSupportProvider(snapshot, isRemoteContext)
            }
            return await AgentForkSupport.supportsFork(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext,
                executableIdentityResolver: forkExecutableIdentityResolver,
                forkCapabilityProbeCache: forkCapabilityProbeCache
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    deinit {
        refreshTask?.cancel()
        forkAvailabilityRefreshTask?.cancel()
        deferredReloadTimer?.cancel()
        forkSupportValidationExpiryTimer?.cancel()
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
        for waiters in activeForkSupportValidationIdentityWaiters.values {
            for waiter in waiters {
                waiter.continuation.resume()
            }
        }
        for waiters in forkValidationRequestCompletionWaiters.values {
            for waiter in waiters {
                waiter.continuation.resume()
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

    func forkSupportProbeExecutableFingerprint(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> String? {
        forkSupportValidation(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteContext,
            fallbackSnapshot: fallbackSnapshot
        )?.executableFingerprint
    }

    func forkSupportProbeCompletedAt(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteContext: Bool = false,
        fallbackSnapshot: SessionRestorableAgentSnapshot? = nil
    ) -> Date? {
        forkSupportValidation(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteContext,
            fallbackSnapshot: fallbackSnapshot
        )?.completedAt
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
        guard (fallbackSnapshot ?? index.snapshot(workspaceId: workspaceId, panelId: panelId)) != nil else {
            if let validatedAt = validatedMissingForkPanels[panelKey],
               dateProvider().timeIntervalSince(validatedAt) < Self.minEventReloadInterval {
                return true
            }
            requestForkAvailabilityRefresh(validating: probeKey)
            return false
        }
        guard (validatedForkPanelKey(for: panelKey) ?? (fallbackSnapshot == nil ? nil : panelKey)) != nil else {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
            return false
        }
        guard let validation = forkSupportValidation(
            workspaceId: panelKey.workspaceId,
            panelId: panelKey.panelId,
            isRemoteContext: isRemoteContext,
            fallbackSnapshot: fallbackSnapshot
        ) else {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
            return false
        }
        if validation.refreshBeforeReuse {
            requestForkAvailabilityRefresh(validating: probeKey, fallbackSnapshot: fallbackSnapshot)
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
            let insertion = insertPendingForkValidation(probeKey, fallbackSnapshot: fallbackSnapshot)
            if let requestID = insertion.requestID {
                pendingRequestIDsOwnedByRequest[probeKey, default: []].insert(requestID)
            } else if let activeWaitKey = insertion.activeWaitKey {
                await waitForActiveForkSupportValidationIdentity(activeWaitKey)
                guard !Task.isCancelled else { return }
                await refreshForkAvailabilityNow(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: fallbackSnapshot
                )
                return
            } else if let pendingWaitProbeKey = insertion.pendingWaitProbeKey,
                      let pendingWaitRequestID = insertion.pendingWaitRequestID {
                await waitForForkValidationRequestCompletion(
                    pendingWaitRequestID,
                    probeKey: pendingWaitProbeKey,
                    ownsRequest: false
                )
                guard !Task.isCancelled else { return }
                await refreshForkAvailabilityNow(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: fallbackSnapshot
                )
                return
            } else if insertion.isFreshValidation {
                return
            }
        }
        if fallbackSnapshot != nil {
            _ = await applyPendingForkValidations(
                pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsOwnedByRequest
            )
            return
        }
        let reloadResult = await reloadIfLiveAgentProcessFingerprintChanged(
            pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsOwnedByRequest
        )
        if !reloadResult.didReload {
            await waitForForkValidationRequestCompletions(pendingRequestIDsOwnedByRequest)
        }
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
            let reloadResult = await self.reloadIfLiveAgentProcessFingerprintChanged()
            self.forkAvailabilityRefreshTask = nil
            self.restartForkAvailabilityRefreshIfPending()
            self.postSharedLiveAgentIndexDidChange(panelIdsByWorkspaceId: reloadResult.panelIdsByWorkspaceId)
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
            _ = await self.reload(forcePublish: true)
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
    ) -> ForkValidationInsertion {
        let requestIdentity = Self.forkValidationRequestIdentity(
            fallbackSnapshot: fallbackSnapshot,
            isRemoteContext: probeKey.isRemoteContext
        )
        if forkSupportValidation(
            workspaceId: probeKey.panelKey.workspaceId,
            panelId: probeKey.panelKey.panelId,
            isRemoteContext: probeKey.isRemoteContext,
            fallbackSnapshot: fallbackSnapshot
        ).map({ !$0.refreshBeforeReuse }) == true {
            return (nil, nil, nil, nil, true)
        }
        if let activeProbeKey = activeForkSupportValidationKey(
            matching: probeKey,
            requestIdentity: requestIdentity
        ) {
            return (
                nil,
                Self.forkValidationWaitKey(probeKey: activeProbeKey, identity: requestIdentity),
                nil,
                nil,
                false
            )
        }
        if let pendingRequestID = pendingForkValidationRequests[probeKey]?.first(where: {
            $0.identity == requestIdentity
        })?.id {
            return (nil, nil, probeKey, pendingRequestID, false)
        }
        let requestID = UUID()
        pendingForkValidationRequests[probeKey, default: []].append((
            id: requestID,
            identity: requestIdentity,
            fallbackSnapshot: fallbackSnapshot
        ))
        return (requestID, nil, nil, nil, false)
    }

    private static func forkValidationRequestIdentity(
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteContext: Bool
    ) -> String {
        guard let fallbackSnapshot else { return "live-index" }
        if let identity = AgentForkSupport.forkValidationIdentity(
            snapshot: fallbackSnapshot,
            isRemoteContext: isRemoteContext
        ) {
            return identity
        }
        return [
            fallbackSnapshot.kind.rawValue,
            fallbackSnapshot.sessionId,
            fallbackSnapshot.workingDirectory ?? "",
            fallbackSnapshot.launchCommand?.launcher ?? "",
            fallbackSnapshot.launchCommand?.executablePath ?? "",
        ].joined(separator: "\u{1f}")
    }

    private static func forkValidationWaitKey(
        probeKey: ForkProbeKey,
        identity: String
    ) -> ForkValidationWaitKey {
        [
            probeKey.panelKey.workspaceId.uuidString,
            probeKey.panelKey.panelId.uuidString,
            String(probeKey.isRemoteContext),
            identity,
        ].joined(separator: "\u{1f}")
    }

    private func activeForkSupportValidationKey(
        matching probeKey: ForkProbeKey,
        requestIdentity: String
    ) -> ForkProbeKey? {
        guard activeForkSupportValidationRequestIdentities[probeKey]?.contains(requestIdentity) == true else {
            return nil
        }
        if activeForkSupportValidationKeys.contains(probeKey),
           activeForkSupportValidationRequestIdentities[probeKey]?.contains(requestIdentity) == true {
            return probeKey
        }
        return activeForkSupportValidationKeys.first { activeProbeKey in
            activeProbeKey.panelKey == probeKey.panelKey
                && activeProbeKey.isRemoteContext == probeKey.isRemoteContext
                && activeForkSupportValidationRequestIdentities[activeProbeKey]?.contains(requestIdentity) == true
        }
    }

    private func removeActiveForkSupportValidationIdentities(
        _ identities: Set<String>,
        for probeKey: ForkProbeKey
    ) {
        guard !identities.isEmpty,
              var activeIdentities = activeForkSupportValidationRequestIdentities[probeKey] else {
            return
        }
        activeIdentities.subtract(identities)
        if activeIdentities.isEmpty {
            activeForkSupportValidationRequestIdentities.removeValue(forKey: probeKey)
        } else {
            activeForkSupportValidationRequestIdentities[probeKey] = activeIdentities
        }
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
                if removePendingForkValidation(probeKey: probeKey, requestID: requestID) {
                    _ = resumeForkValidationRequestCompletionWaiters(for: [requestID])
                } else {
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
        dropping requestIDsByProbeKey: [ForkProbeKey: Set<UUID>],
        restartIfPending: Bool = true
    ) {
        for (probeKey, requests) in pendingRequestsByProbeKey {
            let requestIDs = Set(requests.map(\.id))
            let requestIDsToDrop = (requestIDsByProbeKey[probeKey] ?? [])
                .union(cancelledForkValidationRequestIDs[probeKey] ?? [])
            pruneCancelledForkValidationRequestIDs(
                probeKey: probeKey,
                retiredRequestIDs: requestIDsToDrop
            )
            _ = resumeForkValidationRequestCompletionWaiters(for: requestIDsToDrop)
            let requestsToRestore = requests.filter { !requestIDsToDrop.contains($0.id) }
            retireProcessingForkValidationRequests(probeKey: probeKey, requestIDs: requestIDs)
            guard !requestsToRestore.isEmpty else { continue }
            pendingForkValidationRequests[probeKey, default: []].append(contentsOf: requestsToRestore)
        }
        if restartIfPending {
            restartForkAvailabilityRefreshIfPending()
        }
    }

    private func restartForkAvailabilityRefreshIfPending() {
        guard !pendingForkValidationRequests.isEmpty,
              refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return
        }
        forkAvailabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let reloadResult = await self.reloadIfLiveAgentProcessFingerprintChanged()
            self.forkAvailabilityRefreshTask = nil
            self.restartForkAvailabilityRefreshIfPending()
            self.postSharedLiveAgentIndexDidChange(panelIdsByWorkspaceId: reloadResult.panelIdsByWorkspaceId)
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func waitForActiveForkSupportValidation(_ probeKey: ForkProbeKey) async {
        await withCheckedContinuation { continuation in
            guard activeForkSupportValidationKeys.contains(probeKey) else {
                continuation.resume()
                return
            }
            activeForkSupportValidationWaiters[probeKey, default: []].append(continuation)
        }
    }

    private func waitForActiveForkSupportValidationIdentity(_ waitKey: ForkValidationWaitKey) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard activeForkSupportValidationIdentityIsActive(waitKey) else {
                    continuation.resume()
                    return
                }
                activeForkSupportValidationIdentityWaiters[waitKey, default: []].append((
                    id: waiterID,
                    continuation: continuation
                ))
                if Task.isCancelled {
                    cancelForkSupportValidationIdentityWaiter(waiterID, for: waitKey)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelForkSupportValidationIdentityWaiter(waiterID, for: waitKey)
            }
        }
    }

    private func activeForkSupportValidationIdentityIsActive(_ waitKey: ForkValidationWaitKey) -> Bool {
        for activeProbeKey in activeForkSupportValidationKeys {
            guard let activeIdentities = activeForkSupportValidationRequestIdentities[activeProbeKey] else {
                continue
            }
            for activeIdentity in activeIdentities
                where Self.forkValidationWaitKey(probeKey: activeProbeKey, identity: activeIdentity) == waitKey {
                return true
            }
        }
        return false
    }

    private func cancelForkSupportValidationIdentityWaiter(
        _ waiterID: UUID,
        for waitKey: ForkValidationWaitKey
    ) {
        guard var waiters = activeForkSupportValidationIdentityWaiters[waitKey],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            activeForkSupportValidationIdentityWaiters.removeValue(forKey: waitKey)
        } else {
            activeForkSupportValidationIdentityWaiters[waitKey] = waiters
        }
        waiter.continuation.resume()
    }

    private func waitForForkValidationRequestCompletion(
        _ requestID: UUID,
        probeKey: ForkProbeKey,
        ownsRequest: Bool
    ) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard forkValidationRequestIsWaiting(probeKey: probeKey, requestID: requestID) else {
                    continuation.resume()
                    return
                }
                forkValidationRequestCompletionWaiters[requestID, default: []].append((
                    id: waiterID,
                    continuation: continuation
                ))
                if Task.isCancelled {
                    cancelForkValidationRequestCompletionWaiter(waiterID, requestID: requestID)
                    if ownsRequest {
                        removeOrMarkCancelledForkValidationRequests([probeKey: [requestID]])
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelForkValidationRequestCompletionWaiter(waiterID, requestID: requestID)
                if ownsRequest {
                    self.removeOrMarkCancelledForkValidationRequests([probeKey: [requestID]])
                }
            }
        }
    }

    private func forkValidationRequestIsWaiting(
        probeKey: ForkProbeKey,
        requestID: UUID
    ) -> Bool {
        if pendingForkValidationRequests[probeKey]?.contains(where: { $0.id == requestID }) == true {
            return true
        }
        if processingForkValidationRequestIDs[probeKey]?.contains(requestID) == true {
            return true
        }
        return false
    }

    private func waitForForkValidationRequestCompletions(
        _ requestIDsByProbeKey: [ForkProbeKey: Set<UUID>]
    ) async {
        for (probeKey, requestIDs) in requestIDsByProbeKey {
            for requestID in requestIDs {
                await waitForForkValidationRequestCompletion(
                    requestID,
                    probeKey: probeKey,
                    ownsRequest: true
                )
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func cancelForkValidationRequestCompletionWaiter(
        _ waiterID: UUID,
        requestID: UUID
    ) {
        guard var waiters = forkValidationRequestCompletionWaiters[requestID],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            forkValidationRequestCompletionWaiters.removeValue(forKey: requestID)
        } else {
            forkValidationRequestCompletionWaiters[requestID] = waiters
        }
        waiter.continuation.resume()
    }

    @discardableResult
    private func resumeForkValidationRequestCompletionWaiters(
        for requestIDs: Set<UUID>
    ) -> Bool {
        var resumed = false
        for requestID in requestIDs {
            guard let waiters = forkValidationRequestCompletionWaiters.removeValue(forKey: requestID) else {
                continue
            }
            resumed = resumed || !waiters.isEmpty
            for waiter in waiters {
                waiter.continuation.resume()
            }
        }
        return resumed
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

    @discardableResult
    private func resumeForkSupportValidationIdentityWaiters(for waitKey: ForkValidationWaitKey) -> Bool {
        guard let waiters = activeForkSupportValidationIdentityWaiters.removeValue(forKey: waitKey) else {
            return false
        }
        for waiter in waiters {
            waiter.continuation.resume()
        }
        return !waiters.isEmpty
    }

    private var pendingForkValidationPanels: Set<ForkProbeKey> {
        Set(pendingForkValidationRequests.keys)
    }

    private func pendingForkValidationPanelIdsByWorkspaceId() -> [UUID: Set<UUID>] {
        pendingForkValidationPanels.reduce(into: [UUID: Set<UUID>]()) { result, probeKey in
            result[probeKey.panelKey.workspaceId, default: []].insert(probeKey.panelKey.panelId)
        }
    }

    private static func mergePanelIdsByWorkspaceId(
        _ source: [UUID: Set<UUID>],
        into destination: inout [UUID: Set<UUID>]
    ) {
        for (workspaceId, panelIds) in source {
            destination[workspaceId, default: []].formUnion(panelIds)
        }
    }

    private static func panelIdsByWorkspaceId(for probeKey: ForkProbeKey) -> [UUID: Set<UUID>] {
        [
            probeKey.panelKey.workspaceId: [probeKey.panelKey.panelId],
        ]
    }

    private func postSharedLiveAgentIndexDidChange(panelIdsByWorkspaceId: [UUID: Set<UUID>]) {
        guard !panelIdsByWorkspaceId.isEmpty else {
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            return
        }
        NotificationCenter.default.post(
            name: .sharedLiveAgentIndexDidChange,
            object: self,
            userInfo: [
                "panelIdsByWorkspaceId": panelIdsByWorkspaceId,
            ]
        )
    }

    private func reloadIfLiveAgentProcessFingerprintChanged(
        pendingRequestIDsToRemoveOnCancellation: [ForkProbeKey: Set<UUID>] = [:]
    ) async -> (didReload: Bool, panelIdsByWorkspaceId: [UUID: Set<UUID>]) {
        guard refreshTask == nil else {
            changePending = true
            return (false, [:])
        }
        let panelIdsByWorkspaceId = await reload(
            forcePublish: index == nil,
            pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsToRemoveOnCancellation
        )
        return (true, panelIdsByWorkspaceId)
    }

    private func reload(
        forcePublish: Bool,
        pendingRequestIDsToRemoveOnCancellation: [ForkProbeKey: Set<UUID>] = [:]
    ) async -> [UUID: Set<UUID>] {
        let indexLoader = self.indexLoader
        let result = await Task.detached(priority: .utility) {
            indexLoader()
        }.value
        guard !Task.isCancelled else {
            removeOrMarkCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
            return [:]
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
        return await applyPendingForkValidations(
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
    ) async -> [UUID: Set<UUID>] {
        var processedPanelIdsByWorkspaceId: [UUID: Set<UUID>] = [:]
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
            return processedPanelIdsByWorkspaceId
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
                    _ = resumeForkValidationRequestCompletionWaiters(for: pendingRequestIDsForProbe)
                    _ = resumeForkSupportValidationWaiters(for: probeKey)
                }
            }
            guard !Task.isCancelled else {
                markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                restorePendingForkValidationsAfterCancellation(
                    unprocessedRequestsByProbeKey,
                    dropping: pendingRequestIDsToRemoveOnCancellation
                )
                return processedPanelIdsByWorkspaceId
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
            let activeRequestIdentity = activeRequests[0].identity
            assert(activeRequests.allSatisfy { $0.identity == activeRequestIdentity })
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
            Self.mergePanelIdsByWorkspaceId(
                Self.panelIdsByWorkspaceId(for: probeKey),
                into: &processedPanelIdsByWorkspaceId
            )
            let validationRequiresLiveIndexPanel = fallbackSnapshot == nil
            let snapshot = fallbackSnapshot ?? index?.snapshot(
                workspaceId: panelKey.workspaceId,
                panelId: panelKey.panelId
            )
            guard let snapshot else {
                validatedMissingForkPanels[panelKey] = dateProvider()
                continue
            }
            guard let validationKey = validatedForkPanelKey(for: panelKey)
                ?? (fallbackSnapshot == nil ? nil : panelKey) else {
                continue
            }
            let resolvedProbeKey = ForkProbeKey(
                panelKey: validationKey,
                isRemoteContext: probeKey.isRemoteContext
            )
            guard !activeForkSupportValidationKeys.contains(resolvedProbeKey) else {
                var requestsToRestore = Self.forkValidationRequestDictionary(
                    from: pendingRequestBatches[(batchIndex + 1)...]
                )
                requestsToRestore[probeKey, default: []].append(contentsOf: pendingRequests)
                var requestIDsToDropOnRestore = pendingRequestIDsToRemoveOnCancellation
                requestIDsToDropOnRestore[probeKey, default: []].formUnion(cancelledRequestIDsForProbe)
                restorePendingForkValidationsAfterCancellation(
                    requestsToRestore,
                    dropping: requestIDsToDropOnRestore,
                    restartIfPending: false
                )
                requeuedPendingRequests = true
                deferredForkAvailabilityRefreshAfterActiveValidation = true
                await waitForActiveForkSupportValidation(resolvedProbeKey)
                guard !Task.isCancelled else {
                    removeOrMarkCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                    return processedPanelIdsByWorkspaceId
                }
                deferredForkAvailabilityRefreshAfterActiveValidation = false
                let recursivelyProcessedPanelIdsByWorkspaceId = await applyPendingForkValidations(
                    pendingRequestIDsToRemoveOnCancellation: pendingRequestIDsToRemoveOnCancellation
                )
                Self.mergePanelIdsByWorkspaceId(
                    recursivelyProcessedPanelIdsByWorkspaceId,
                    into: &processedPanelIdsByWorkspaceId
                )
                return processedPanelIdsByWorkspaceId
            }
            activeForkSupportValidationKeys.insert(resolvedProbeKey)
            let activeRequestIdentities: Set<String> = [activeRequestIdentity]
            activeForkSupportValidationRequestIdentities[probeKey, default: []].formUnion(activeRequestIdentities)
            activeForkSupportValidationRequestIdentities[resolvedProbeKey, default: []].formUnion(activeRequestIdentities)
            defer {
                activeForkSupportValidationKeys.remove(resolvedProbeKey)
                removeActiveForkSupportValidationIdentities(activeRequestIdentities, for: probeKey)
                if resolvedProbeKey != probeKey {
                    removeActiveForkSupportValidationIdentities(activeRequestIdentities, for: resolvedProbeKey)
                }
                let resumedResolvedWaiters = resumeForkSupportValidationWaiters(for: resolvedProbeKey)
                let resumedOriginalWaiters = resolvedProbeKey != probeKey
                    ? resumeForkSupportValidationWaiters(for: probeKey)
                    : false
                let resolvedIdentityWaitKey = Self.forkValidationWaitKey(
                    probeKey: resolvedProbeKey,
                    identity: activeRequestIdentity
                )
                let originalIdentityWaitKey = Self.forkValidationWaitKey(
                    probeKey: probeKey,
                    identity: activeRequestIdentity
                )
                let resumedResolvedIdentityWaiters = resumeForkSupportValidationIdentityWaiters(
                    for: resolvedIdentityWaitKey
                )
                let resumedOriginalIdentityWaiters = resolvedIdentityWaitKey != originalIdentityWaitKey
                    ? resumeForkSupportValidationIdentityWaiters(for: originalIdentityWaitKey)
                    : false
                let resumedWaiters = resumedResolvedWaiters
                    || resumedOriginalWaiters
                    || resumedResolvedIdentityWaiters
                    || resumedOriginalIdentityWaiters
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
                let executableResolutionBeforeProbe: AgentForkSupport.ForkValidationExecutableResolution
                if requiresExecutableIdentity {
                    executableResolutionBeforeProbe = await forkValidationExecutableResolution(
                        snapshot: snapshot,
                        isRemoteContext: probeKey.isRemoteContext
                    )
                    guard !Task.isCancelled else {
                        markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                        removeForkSupportValidation(for: resolvedProbeKey)
                        restorePendingForkValidationsAfterCancellation(
                            unprocessedRequestsByProbeKey,
                            dropping: pendingRequestIDsToRemoveOnCancellation
                        )
                        return processedPanelIdsByWorkspaceId
                    }
                } else {
                    executableResolutionBeforeProbe = ("notRequired", nil, nil, nil, [])
                }
                let executableFingerprintBeforeProbe = requiresExecutableIdentity
                    ? AgentForkSupport.forkValidationExecutableFingerprint(executableResolutionBeforeProbe)
                    : nil
                let watchGeneration: UUID?
                let refreshBeforeReuse: Bool
                switch executableResolutionBeforeProbe.status {
                case "notRequired":
                    guard !requiresExecutableIdentity else {
                        removeForkSupportValidation(for: resolvedProbeKey)
                        continue
                    }
                    clearForkExecutableWatch(for: resolvedProbeKey)
                    watchGeneration = nil
                    refreshBeforeReuse = false
                case "skipRemoteLikeContext":
                    clearForkExecutableWatch(for: resolvedProbeKey)
                    watchGeneration = nil
                    refreshBeforeReuse = false
                case "unresolved":
                    storeRejectedForkSupportValidation(
                        identity: identity,
                        for: resolvedProbeKey,
                        requiresLiveIndexPanel: validationRequiresLiveIndexPanel,
                        refreshBeforeReuse: false
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
                        requestingPanelKey: panelKey,
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
                        return processedPanelIdsByWorkspaceId
                    }
                    refreshBeforeReuse = watchGeneration == nil
                default:
                    removeForkSupportValidation(for: resolvedProbeKey)
                    continue
                }
                let isSupported = await supportsFork(
                    snapshot: snapshot,
                    isRemoteContext: probeKey.isRemoteContext
                )
                guard !Task.isCancelled else {
                    markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                    removeForkSupportValidation(for: resolvedProbeKey)
                    restorePendingForkValidationsAfterCancellation(
                        unprocessedRequestsByProbeKey,
                        dropping: pendingRequestIDsToRemoveOnCancellation
                    )
                    return processedPanelIdsByWorkspaceId
                }
                if requiresExecutableIdentity {
                    let executableResolutionAfterProbe = await forkValidationExecutableResolution(
                        snapshot: snapshot,
                        isRemoteContext: probeKey.isRemoteContext
                    )
                    guard !Task.isCancelled else {
                        markCancelledForkValidationRequests(pendingRequestIDsToRemoveOnCancellation)
                        removeForkSupportValidation(for: resolvedProbeKey)
                        restorePendingForkValidationsAfterCancellation(
                            unprocessedRequestsByProbeKey,
                            dropping: pendingRequestIDsToRemoveOnCancellation
                        )
                        return processedPanelIdsByWorkspaceId
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
                    executableFingerprint: executableFingerprintBeforeProbe,
                    refreshBeforeReuse: refreshBeforeReuse,
                    isSupported: isSupported,
                    completedAt: dateProvider(),
                    requiresLiveIndexPanel: validationRequiresLiveIndexPanel
                )
                scheduleForkSupportValidationExpiryPrune(now: dateProvider())
            } else {
                removeForkSupportValidation(for: resolvedProbeKey)
            }
        }
        if activeForkSupportValidationKeys.isEmpty {
            restartForkAvailabilityRefreshIfPending()
        }
        return processedPanelIdsByWorkspaceId
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
        var batches: [ForkValidationRequestBatch] = []
        for (probeKey, requests) in requestsByProbeKey {
            var requestsByIdentity: [String: [ForkValidationRequest]] = [:]
            for request in requests {
                requestsByIdentity[request.identity, default: []].append(request)
            }
            for identity in requestsByIdentity.keys.sorted() {
                batches.append((probeKey: probeKey, requests: requestsByIdentity[identity] ?? []))
            }
        }
        return batches.sorted { lhs, rhs in
            forkValidationRequestSortKey(lhs) < forkValidationRequestSortKey(rhs)
        }
    }

    private static func forkValidationRequestSortKey(_ batch: ForkValidationRequestBatch) -> String {
        [
            batch.probeKey.panelKey.workspaceId.uuidString,
            batch.probeKey.panelKey.panelId.uuidString,
            String(batch.probeKey.isRemoteContext),
            batch.requests.first?.identity ?? "",
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
        scheduleForkSupportValidationExpiryPrune(now: now)
    }

    private func scheduleForkSupportValidationExpiryPrune(now: Date = Date()) {
        forkSupportValidationExpiryTimer?.cancel()
        forkSupportValidationExpiryTimer = nil
        let nextExpiry = validatedForkSupport.values
            .map { $0.completedAt.addingTimeInterval(Self.forkAvailabilityProbeTTL) }
            .filter { $0 > now }
            .min()
        guard let nextExpiry else { return }
        let delay = max(0, nextExpiry.timeIntervalSince(now))
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.forkSupportValidationExpiryTimer?.cancel()
                self.forkSupportValidationExpiryTimer = nil
                self.pruneExpiredForkSupportValidations(now: self.dateProvider())
            }
        }
        forkSupportValidationExpiryTimer = timer
        timer.resume()
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
            executableFingerprint: nil,
            refreshBeforeReuse: refreshBeforeReuse,
            isSupported: false,
            completedAt: dateProvider(),
            requiresLiveIndexPanel: requiresLiveIndexPanel
        )
        scheduleForkSupportValidationExpiryPrune(now: dateProvider())
    }

    private func clearForkExecutableWatch(for probeKey: ForkProbeKey) {
        forkExecutableWatchGenerations.removeValue(forKey: probeKey)
        guard let watchKey = forkExecutableWatchKeysByProbeKey.removeValue(forKey: probeKey),
              var record = forkExecutableWatchRecords[watchKey] else {
            return
        }
        record.probeKeys.remove(probeKey)
        record.panelAliasesByProbeKey.removeValue(forKey: probeKey)
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
        let panelKeys = Set(
            probeKeys.map(\.panelKey)
                + record.panelAliasesByProbeKey.values.flatMap { $0 }
        )
        removeForkExecutableWatchRecord(for: watchKey)
        for probeKey in probeKeys {
            validatedForkSupport.removeValue(forKey: probeKey)
        }
        let panelIdsByWorkspaceId = panelKeys.reduce(
            into: [UUID: Set<UUID>]()
        ) { result, panelKey in
            result[panelKey.workspaceId, default: []].insert(panelKey.panelId)
        }
        NotificationCenter.default.post(
            name: .sharedLiveAgentIndexDidChange,
            object: self,
            userInfo: [
                "panelIdsByWorkspaceId": panelIdsByWorkspaceId,
            ]
        )
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
        requestingPanelKey: RestorableAgentSessionIndex.PanelKey,
        lookupPath: String?,
        realPath: String?,
        watchDirectories: [String]
    ) async -> UUID? {
        clearForkExecutableWatch(for: probeKey)
        guard let lookupPath, let realPath else { return nil }
        let resolvedWatchPaths = await resolveForkExecutableWatchPaths(
            lookupPath: lookupPath,
            realPath: realPath,
            watchDirectories: watchDirectories
        )
        guard let watchPaths = resolvedWatchPaths else {
            return nil
        }
        let watchKey: ForkExecutableWatchKey = watchPaths
        if var record = forkExecutableWatchRecords[watchKey] {
            record.probeKeys.insert(probeKey)
            record.panelAliasesByProbeKey[probeKey, default: []].insert(requestingPanelKey)
            forkExecutableWatchRecords[watchKey] = record
            forkExecutableWatchKeysByProbeKey[probeKey] = watchKey
            forkExecutableWatchGenerations[probeKey] = record.generation
            return record.generation
        }

        let generation = UUID()
        pruneExpiredForkSupportValidations(now: dateProvider())
        if var record = forkExecutableWatchRecords[watchKey] {
            record.probeKeys.insert(probeKey)
            record.panelAliasesByProbeKey[probeKey, default: []].insert(requestingPanelKey)
            forkExecutableWatchRecords[watchKey] = record
            forkExecutableWatchKeysByProbeKey[probeKey] = watchKey
            forkExecutableWatchGenerations[probeKey] = record.generation
            return record.generation
        }
        let activeWatchCount = forkExecutableWatchRecords.values.reduce(0) { partial, record in
            partial + record.sources.count
        }
        guard activeWatchCount + watchPaths.count <= Self.maximumForkExecutableWatchSourceCountCeiling else {
            return nil
        }
        guard reserveForkExecutableWatchDescriptors(count: watchPaths.count) else {
            return nil
        }
        let openedFileDescriptors = await openForkExecutableWatchFileDescriptorsBounded(
            watchPaths: watchPaths
        )
        releaseForkExecutableWatchDescriptorReservation(count: watchPaths.count)
        guard let openedFileDescriptors else {
            return nil
        }
        if var record = forkExecutableWatchRecords[watchKey] {
            openedFileDescriptors.forEach { Darwin.close($0) }
            record.probeKeys.insert(probeKey)
            record.panelAliasesByProbeKey[probeKey, default: []].insert(requestingPanelKey)
            forkExecutableWatchRecords[watchKey] = record
            forkExecutableWatchKeysByProbeKey[probeKey] = watchKey
            forkExecutableWatchGenerations[probeKey] = record.generation
            return record.generation
        }
        guard Self.forkExecutableWatchDescriptorReserveIsSatisfied(
            pendingReservationCount: pendingForkExecutableWatchDescriptorReservations
        ) else {
            openedFileDescriptors.forEach { Darwin.close($0) }
            return nil
        }
        let activeWatchCountAfterOpen = forkExecutableWatchRecords.values.reduce(0) { partial, record in
            partial + record.sources.count
        }
        guard activeWatchCountAfterOpen + openedFileDescriptors.count <= Self.maximumForkExecutableWatchSourceCountCeiling else {
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
            panelAliasesByProbeKey: [probeKey: [requestingPanelKey]],
            sources: sources
        )
        forkExecutableWatchKeysByProbeKey[probeKey] = watchKey
        forkExecutableWatchGenerations[probeKey] = generation
        for source in sources {
            source.resume()
        }
        return generation
    }

    private func resolveForkExecutableWatchPaths(
        lookupPath: String,
        realPath: String,
        watchDirectories: [String]
    ) async -> ForkExecutableWatchKey? {
        let key = Self.forkExecutableWatchPathTaskKey(
            lookupPath: lookupPath,
            realPath: realPath,
            watchDirectories: watchDirectories
        )
        guard forkExecutableWatchPathTasks[key] == nil,
              !timedOutForkExecutableWatchPathKeys.contains(key),
              outstandingForkExecutableWatchInstallWorkCount
                < Self.maximumOutstandingForkExecutableWatchInstallWork else {
            return nil
        }
        let task = Task.detached(priority: .utility) {
            Self.forkExecutableWatchPaths(
                lookupPath: lookupPath,
                realPath: realPath,
                watchDirectories: watchDirectories
            )
        }
        forkExecutableWatchPathTasks[key] = task
        Task { @MainActor in
            _ = await task.value
            self.forkExecutableWatchPathTasks[key] = nil
            self.timedOutForkExecutableWatchPathKeys.remove(key)
        }
        return await boundedForkExecutableWatchTaskValue(
            task: task,
            timeoutValue: Optional<ForkExecutableWatchKey>.none,
            onTimeout: {
                self.timedOutForkExecutableWatchPathKeys.insert(key)
            }
        )
    }

    private func openForkExecutableWatchFileDescriptorsBounded(
        watchPaths: ForkExecutableWatchKey
    ) async -> [Int32]? {
        let key = Self.forkExecutableWatchOpenTaskKey(watchPaths: watchPaths)
        guard forkExecutableWatchOpenTasks[key] == nil,
              !timedOutForkExecutableWatchOpenKeys.contains(key),
              outstandingForkExecutableWatchInstallWorkCount
                < Self.maximumOutstandingForkExecutableWatchInstallWork else {
            return nil
        }
        let task = Task.detached(priority: .utility) {
            Self.openForkExecutableWatchFileDescriptors(watchPaths: watchPaths)
        }
        forkExecutableWatchOpenTasks[key] = task
        Task { @MainActor in
            _ = await task.value
            self.timedOutForkExecutableWatchOpenKeys.remove(key)
            self.forkExecutableWatchOpenTasks[key] = nil
        }
        return await boundedForkExecutableWatchTaskValue(
            task: task,
            timeoutValue: Optional<[Int32]>.none,
            onTimeout: {
                self.timedOutForkExecutableWatchOpenKeys.insert(key)
            },
            onLostValue: { fileDescriptors in
                fileDescriptors?.forEach { Darwin.close($0) }
            }
        )
    }

    private func boundedForkExecutableWatchTaskValue<Value: Sendable>(
        task: Task<Value, Never>,
        timeoutValue: Value,
        onTimeout: @MainActor @escaping () -> Void,
        onLostValue: @Sendable @escaping (Value) -> Void = { _ in }
    ) async -> Value {
        return await withCheckedContinuation { continuation in
            let gate = AgentForkTimeoutResumeGate(continuation)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(
                deadline: .now() + .nanoseconds(
                    Int(Self.forkExecutableWatchInstallTimeoutNanoseconds)
                )
            )
            timer.setEventHandler {
                timer.setEventHandler {}
                timer.cancel()
                let delivered = gate.resume(returning: timeoutValue)
                if delivered {
                    Task { @MainActor in
                        onTimeout()
                    }
                }
            }
            timer.resume()
            Task.detached(priority: .utility) {
                let value = await task.value
                timer.setEventHandler {}
                timer.cancel()
                let delivered = gate.resume(returning: value)
                if !delivered {
                    onLostValue(value)
                }
            }
        }
    }

    private var outstandingForkExecutableWatchInstallWorkCount: Int {
        forkExecutableWatchPathTasks.count + forkExecutableWatchOpenTasks.count
    }

    nonisolated private static func forkExecutableWatchPathTaskKey(
        lookupPath: String,
        realPath: String,
        watchDirectories: [String]
    ) -> String {
        ([lookupPath, realPath] + watchDirectories.sorted()).joined(separator: "\u{1f}")
    }

    nonisolated private static func forkExecutableWatchOpenTaskKey(
        watchPaths: ForkExecutableWatchKey
    ) -> String {
        watchPaths.joined(separator: "\u{1f}")
    }

    private func reserveForkExecutableWatchDescriptors(count: Int) -> Bool {
        guard count > 0 else { return false }
        guard count <= forkExecutableWatchSourceBudgetProvider(
            pendingForkExecutableWatchDescriptorReservations
        ) else {
            return false
        }
        pendingForkExecutableWatchDescriptorReservations += count
        return true
    }

    private func releaseForkExecutableWatchDescriptorReservation(count: Int) {
        pendingForkExecutableWatchDescriptorReservations = max(
            0,
            pendingForkExecutableWatchDescriptorReservations - count
        )
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
            let fileDescriptor = Darwin.open(watchPath, forkExecutableWatchOpenFlags)
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
        let fd = open(dir, Self.forkExecutableWatchOpenFlags)
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
