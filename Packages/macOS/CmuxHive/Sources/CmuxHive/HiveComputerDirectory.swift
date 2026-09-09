internal import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileShell
internal import CmuxMobileShellModel
public import Foundation
public import Observation

/// The account's computers, merged live from three sources: the team device
/// registry (`GET /api/devices`), the local paired-computer store, and the
/// presence service's online/offline stream.
///
/// This is the macOS counterpart of the iOS app's Computers screen state:
/// same registry client, same paired store, same presence protocol — composed
/// for the Settings › Computers pane and the remote-Mac viewer instead of the
/// phone UI. All dependencies are injected protocol seams, so the merge and
/// the pair/unpair actions are unit-testable with scripted fakes.
@MainActor
@Observable
public final class HiveComputerDirectory {
    /// The merged, sorted computer rows (this computer first, then online
    /// computers, then by recency).
    public private(set) var computers: [HiveComputer] = []
    /// Whether a registry refresh is currently in flight.
    public private(set) var isRefreshing = false
    /// Whether the most recent refresh failed to reach the registry (rows then
    /// show local/paired data only).
    public private(set) var lastRefreshFailed = false

    @ObservationIgnored private let registry: any DeviceRegistryRefreshing
    @ObservationIgnored let pairedStore: any MobilePairedMacStoring
    @ObservationIgnored private let presence: (any PresenceSubscribing)?
    @ObservationIgnored let ownDeviceID: String
    @ObservationIgnored let scopeProvider: @Sendable () async -> HiveAccountScope
    @ObservationIgnored let linkDecoder: HivePairingLinkDecoder
    @ObservationIgnored let viewerRoutePolicy: HiveViewerRoutePolicy
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private let presenceRetryDelay: @Sendable (_ attempt: Int) async -> Void
    @ObservationIgnored private let rowBuilder: HiveComputerRowBuilder

    @ObservationIgnored private var presenceMap = PresenceMap()
    @ObservationIgnored private(set) var registryDevices: [RegistryDevice] = []
    @ObservationIgnored private var pairedRecords: [MobilePairedMac] = []
    @ObservationIgnored private var registryByID: [String: RegistryDevice] = [:]
    @ObservationIgnored private var pairedByID: [String: MobilePairedMac] = [:]
    @ObservationIgnored private var pairedRecordsByID: [String: [MobilePairedMac]] = [:]
    @ObservationIgnored private(set) var loadedScope: HiveAccountScope?
    @ObservationIgnored private(set) var scopeGeneration = 0
    @ObservationIgnored private var listeners: [UUID: AsyncStream<[HiveComputer]>.Continuation] = [:]
    @ObservationIgnored private var deviceListeners:
        [String: [UUID: AsyncStream<HiveComputer?>.Continuation]] = [:]
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private var presenceGeneration = 0
    @ObservationIgnored private var refreshTask: Task<Int?, Never>?
    @ObservationIgnored private var refreshRequestID: UUID?

    /// Creates a directory over injected source seams.
    ///
    /// - Parameters:
    ///   - registry: The team device registry client.
    ///   - pairedStore: The local paired-computer store.
    ///   - presence: The live presence stream, or `nil` to run registry-only
    ///     (tests, previews).
    ///   - ownDeviceID: This computer's registry device id, used to mark the
    ///     "This Mac" row and block self-pairing.
    ///   - scopeProvider: Supplies the current account scope per operation, so
    ///     a signed-out or team-switched session is read at use time.
    ///   - linkDecoder: Policy-carrying decoder for pasted pairing links.
    ///   - now: Clock seam for pairing timestamps.
    ///   - presenceRetryDelay: Awaited between presence stream retries with the
    ///     consecutive-failure attempt count; production passes a bounded
    ///     backoff sleep, tests pass a recorder that returns immediately.
    public init(
        registry: any DeviceRegistryRefreshing,
        pairedStore: any MobilePairedMacStoring,
        presence: (any PresenceSubscribing)?,
        ownDeviceID: String,
        scopeProvider: @escaping @Sendable () async -> HiveAccountScope,
        linkDecoder: HivePairingLinkDecoder,
        now: @escaping @Sendable () -> Date = { Date() },
        presenceRetryDelay: @escaping @Sendable (_ attempt: Int) async -> Void
    ) {
        self.registry = registry
        self.pairedStore = pairedStore
        self.presence = presence
        self.ownDeviceID = cmxCanonicalDeviceID(ownDeviceID)
        self.scopeProvider = scopeProvider
        self.linkDecoder = linkDecoder
        let routePolicy = HiveViewerRoutePolicy(allowsLoopbackRoutes: linkDecoder.allowsLoopbackRoutes)
        self.viewerRoutePolicy = routePolicy
        self.now = now
        self.presenceRetryDelay = presenceRetryDelay
        self.rowBuilder = HiveComputerRowBuilder(ownDeviceID: ownDeviceID, viewerRoutePolicy: routePolicy)
    }

    // MARK: - Observation

    /// A stream of merged computer lists, yielding the current value
    /// immediately and then on every change.
    ///
    /// The first active stream starts the presence subscription; when the last
    /// stream terminates the subscription stops, so an unopened Computers pane
    /// costs no presence socket.
    public func updates() -> AsyncStream<[HiveComputer]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[HiveComputer]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        listeners[id] = continuation
        continuation.yield(computers)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeListener(id: id)
            }
        }
        if !listeners.isEmpty {
            startPresenceIfNeeded()
        }
        return stream
    }

    /// A device-scoped stream for route/presence changes affecting one
    /// computer. Unlike ``updates()``, it never allocates or broadcasts the
    /// full team snapshot to a mirror/window listener.
    ///
    /// - Parameter deviceID: The registry device id to observe.
    /// - Returns: The current row, then only that row's changes; `nil` means
    ///   the device disappeared from the current account scope.
    public func updates(for deviceID: String) -> AsyncStream<HiveComputer?> {
        let id = UUID()
        let key = cmxCanonicalDeviceID(deviceID)
        let (stream, continuation) = AsyncStream<HiveComputer?>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        deviceListeners[key, default: [:]][id] = continuation
        continuation.yield(computers.first {
            $0.deviceID == key
        })
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeDeviceListener(id: id, deviceID: key)
            }
        }
        startPresenceIfNeeded()
        return stream
    }

    private func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
        stopPresenceIfUnused()
    }

    private func removeDeviceListener(id: UUID, deviceID: String) {
        deviceListeners[deviceID]?.removeValue(forKey: id)
        if deviceListeners[deviceID]?.isEmpty == true {
            deviceListeners.removeValue(forKey: deviceID)
        }
        stopPresenceIfUnused()
    }

    private func stopPresenceIfUnused() {
        if listeners.isEmpty && deviceListeners.isEmpty {
            presenceGeneration &+= 1
            presenceTask?.cancel()
            presenceTask = nil
            invalidatePresence()
        }
    }

    // MARK: - Refresh

    /// Re-fetch the registry device list and reload local pairings, then
    /// rebuild the merged rows. Transient registry failures keep the previous
    /// registry data; an auth rejection clears it (the scope changed).
    public func refresh() async {
        let generationBeforeRead = scopeGeneration
        let scope = await scopeProvider()
        guard generationBeforeRead == scopeGeneration || loadedScope == scope else { return }
        let generation = activateScope(scope)
        while !Task.isCancelled {
            guard generation == scopeGeneration, loadedScope == scope else { return }
            if refreshTask == nil {
                refreshRequestID = UUID()
                refreshTask = Task { [weak self] in
                    await self?.performRefresh(scope: scope, generation: generation)
                }
            }
            guard let task = refreshTask else { return }
            let requestID = refreshRequestID
            let completedGeneration = await task.value
            if refreshRequestID == requestID {
                refreshTask = nil
                refreshRequestID = nil
            }
            guard generation == scopeGeneration, loadedScope == scope else { return }
            guard let completedGeneration else { return }
            if completedGeneration == generation {
                _ = await isCurrentScope(scope, generation: generation)
                return
            }
            // An old account's completed request is not a refresh of the
            // current account. Join or start its one shared successor.
        }
    }

    private func performRefresh(scope: HiveAccountScope, generation: Int) async -> Int {
        guard await isCurrentScope(scope, generation: generation) else { return generation }
        isRefreshing = true
        defer { isRefreshing = false }
        guard scope.stackUserID != nil else {
            clearLoadedSources()
            rebuild()
            return generation
        }
        switch await registry.listDevices() {
        case .ok(let devices):
            guard await isCurrentScope(scope, generation: generation) else { return generation }
            registryDevices = devices
            registryByID = Dictionary(
                devices.map { (cmxCanonicalDeviceID($0.deviceId), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            lastRefreshFailed = false
        case .authRejected:
            guard await isCurrentScope(scope, generation: generation) else { return generation }
            registryDevices = []
            registryByID = [:]
            lastRefreshFailed = false
        case .transientFailure:
            guard await isCurrentScope(scope, generation: generation) else { return generation }
            lastRefreshFailed = true
        }
        guard await isCurrentScope(scope, generation: generation) else { return generation }
        await reloadPairedRecords(scope: scope)
        guard await isCurrentScope(scope, generation: generation) else { return generation }
        rebuild()
        return generation
    }

    func reloadPairedRecords(scope: HiveAccountScope) async {
        guard loadedScope == scope else { return }
        let generation = scopeGeneration
        guard scope.stackUserID != nil else {
            pairedRecords = []
            pairedByID = [:]
            pairedRecordsByID = [:]
            return
        }
        do {
            let records = try await pairedStore.loadAll(
                stackUserID: scope.stackUserID,
                teamID: scope.teamID
            )
            guard await isCurrentScope(scope, generation: generation) else { return }
            pairedRecords = records
            pairedByID = rowBuilder.indexPairedRecords(pairedRecords)
            pairedRecordsByID = Dictionary(grouping: pairedRecords) { cmxCanonicalDeviceID($0.macDeviceID) }
        } catch {
            // Keep the previous local list; a store read failure must not
            // wipe rows the registry no longer needs to confirm.
        }
    }

    /// Clear account-owned rows when auth transitions to signed out.
    public func clearForSignOut() {
        _ = activateScope(HiveAccountScope(stackUserID: nil, teamID: nil))
        clearLoadedSources()
        rebuild()
    }

    private func clearLoadedSources() {
        registryDevices = []
        pairedRecords = []
        registryByID = [:]
        pairedByID = [:]
        pairedRecordsByID = [:]
        presenceMap = PresenceMap()
        presenceGeneration &+= 1
        presenceTask?.cancel()
        presenceTask = nil
        computers = []
        lastRefreshFailed = false
    }

    func activateScope(_ scope: HiveAccountScope) -> Int {
        guard loadedScope != scope else { return scopeGeneration }
        // A scoped viewer must never survive an account/team transition. End
        // each device stream before replacing the rows so its mirror/window
        // owner tears down the old team's RPC session instead of retaining it.
        let deviceContinuations = deviceListeners.values.flatMap { $0.values }
        deviceListeners.removeAll()
        for continuation in deviceContinuations {
            continuation.yield(nil)
            continuation.finish()
        }
        loadedScope = scope
        scopeGeneration &+= 1
        registryDevices = []
        pairedRecords = []
        registryByID = [:]
        pairedByID = [:]
        pairedRecordsByID = [:]
        presenceMap = PresenceMap()
        presenceGeneration &+= 1
        presenceTask?.cancel()
        presenceTask = nil
        computers = []
        lastRefreshFailed = false
        for (_, continuation) in listeners {
            continuation.yield(computers)
        }
        if !listeners.isEmpty {
            startPresenceIfNeeded()
        }
        return scopeGeneration
    }

    func isCurrentScope(_ scope: HiveAccountScope, generation: Int) async -> Bool {
        guard generation == scopeGeneration, loadedScope == scope else { return false }
        let latest = await scopeProvider()
        guard generation == scopeGeneration, loadedScope == scope else { return false }
        guard latest == scope else {
            _ = activateScope(latest)
            return false
        }
        return true
    }

    // MARK: - Presence

    private func startPresenceIfNeeded() {
        guard presenceTask == nil, let presence else { return }
        presenceGeneration &+= 1
        let generation = presenceGeneration
        presenceTask = Task { [weak self] in
            await self?.runPresenceLoop(presence: presence, generation: generation)
        }
    }

    private func runPresenceLoop(
        presence: any PresenceSubscribing,
        generation: Int
    ) async {
        var consecutiveFailures = 0
        while !Task.isCancelled, generation == presenceGeneration {
            do {
                let stream = try await presence.subscribe()
                for try await update in stream {
                    guard generation == presenceGeneration else { return }
                    consecutiveFailures = 0
                    presenceMap.apply(update)
                    rebuild(affectedDeviceIDs: affectedDeviceIDs(for: update))
                }
            } catch {
                consecutiveFailures += 1
            }
            if Task.isCancelled { return }
            invalidatePresence()
            // The presence stream ended (server deadline) or failed; the
            // injected delay bounds the resubscribe backoff and is cancelled
            // with this task.
            await presenceRetryDelay(consecutiveFailures)
        }
    }

    // MARK: - Merge

    private func invalidatePresence() {
        presenceMap = PresenceMap()
        rebuild()
    }

    func rebuild(affectedDeviceIDs: Set<String>? = nil) {
        let previousComputers = computers
        let changedIDs: Set<String>
        if let affectedDeviceIDs {
            changedIDs = Set(affectedDeviceIDs.map(cmxCanonicalDeviceID))
            for deviceID in changedIDs {
                if let oldIndex = computers.firstIndex(where: { $0.deviceID == deviceID }) {
                    computers.remove(at: oldIndex)
                }
                guard let row = rowBuilder.makeRow(
                    registry: registryByID[deviceID],
                    paired: pairedByID[deviceID],
                    pairedRecords: pairedRecordsByID[deviceID] ?? [],
                    presence: presenceMap
                ) else { continue }
                let insertionIndex = computers.firstIndex {
                    rowBuilder.comesBefore(row, $0)
                } ?? computers.endIndex
                computers.insert(row, at: insertionIndex)
            }
        } else {
            changedIDs = Set(
                (previousComputers.map(\.deviceID)
                    + registryDevices.map(\.deviceId)
                    + pairedRecords.map(\.macDeviceID)).map(cmxCanonicalDeviceID)
            )
            computers = rowBuilder.makeRows(
                registry: registryDevices,
                paired: pairedRecords,
                presence: presenceMap
            )
        }
        if previousComputers != computers {
            for (_, continuation) in listeners {
                continuation.yield(computers)
            }
        }
        for deviceID in changedIDs {
            let row = computers.first {
                $0.deviceID == deviceID
            }
            let key = cmxCanonicalDeviceID(deviceID)
            deviceListeners[key]?.values.forEach { continuation in
                continuation.yield(row)
            }
        }
    }

    private func affectedDeviceIDs(for update: PresenceUpdate) -> Set<String>? {
        switch update {
        case .snapshot:
            return nil
        case .online(let instance), .routes(let instance), .offline(let instance, _):
            return [instance.deviceId]
        case .seen(let deviceID, _, _):
            return [deviceID]
        }
    }

}
