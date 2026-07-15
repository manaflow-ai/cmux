internal import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileShell
public import CmuxMobileShellModel
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
    @ObservationIgnored private let pairedStore: any MobilePairedMacStoring
    @ObservationIgnored private let presence: (any PresenceSubscribing)?
    @ObservationIgnored private let ownDeviceID: String
    @ObservationIgnored private let scopeProvider: @Sendable () async -> HiveAccountScope
    @ObservationIgnored private let linkDecoder: HivePairingLinkDecoder
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let presenceRetryDelay: @Sendable (_ attempt: Int) async -> Void

    @ObservationIgnored private var presenceMap = PresenceMap()
    @ObservationIgnored private var registryDevices: [RegistryDevice] = []
    @ObservationIgnored private var pairedRecords: [MobilePairedMac] = []
    @ObservationIgnored private var listeners: [UUID: AsyncStream<[HiveComputer]>.Continuation] = [:]
    @ObservationIgnored private var presenceTask: Task<Void, Never>?

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
        self.ownDeviceID = ownDeviceID
        self.scopeProvider = scopeProvider
        self.linkDecoder = linkDecoder
        self.now = now
        self.presenceRetryDelay = presenceRetryDelay
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
        startPresenceIfNeeded()
        return stream
    }

    private func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
        if listeners.isEmpty {
            presenceTask?.cancel()
            presenceTask = nil
        }
    }

    // MARK: - Refresh

    /// Re-fetch the registry device list and reload local pairings, then
    /// rebuild the merged rows. Transient registry failures keep the previous
    /// registry data; an auth rejection clears it (the scope changed).
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let scope = await scopeProvider()
        switch await registry.listDevices() {
        case .ok(let devices):
            registryDevices = devices
            lastRefreshFailed = false
        case .authRejected:
            registryDevices = []
            lastRefreshFailed = false
        case .transientFailure:
            lastRefreshFailed = true
        }
        await reloadPairedRecords(scope: scope)
        rebuild()
    }

    private func reloadPairedRecords(scope: HiveAccountScope) async {
        do {
            pairedRecords = try await pairedStore.loadAll(
                stackUserID: scope.stackUserID,
                teamID: scope.teamID
            )
        } catch {
            // Keep the previous local list; a store read failure must not
            // wipe rows the registry no longer needs to confirm.
        }
    }

    // MARK: - Pairing

    /// Pair a computer from its registry row: persist its best instance's
    /// routes into the local paired store.
    public func pair(deviceID: String) async -> HivePairOutcome {
        guard let computer = computers.first(where: { $0.deviceID == deviceID }),
              computer.isPairableHost else {
            return .noRoutes
        }
        guard let best = computer.bestPairingRoutes else { return .noRoutes }
        return await persistPairing(
            macDeviceID: deviceID,
            displayName: computer.displayName,
            routes: best.routes,
            instanceTag: best.instanceTag
        )
    }

    /// Pair from the 6-digit code another Mac's "Pair This Mac" row is
    /// showing.
    ///
    /// The code is a registry rendezvous: the host advertises it (with an
    /// expiry) in its instance labels, so the claim re-fetches the registry
    /// and pairs with the unique instance whose unexpired code matches.
    /// Non-digits in the input are ignored, so `"042 117"` claims `042117`.
    ///
    /// - Parameter rawCode: The user-typed code.
    /// - Returns: The pair outcome; ambiguous or expired codes report
    ///   ``HivePairOutcome/codeNotFound``.
    public func pair(code rawCode: String) async -> HivePairOutcome {
        guard let code = CmxPairingCode.normalizedClaimInput(rawCode) else {
            return .codeNotFound
        }
        await refresh()
        let claimTime = now()
        let matches = registryDevices.flatMap { device in
            device.instances
                .filter { $0.hasRoutes && $0.activePairingCode(now: claimTime)?.code == code }
                .map { (device: device, instance: $0) }
        }
        // Exactly one live match may claim; a 6-digit collision inside one
        // team is ambiguous and reports not-found rather than guessing.
        guard matches.count == 1, let match = matches.first else { return .codeNotFound }
        guard match.device.deviceId != ownDeviceID else { return .loopbackRejected }
        return await persistPairing(
            macDeviceID: match.device.deviceId,
            displayName: match.device.displayName,
            routes: match.instance.routes,
            instanceTag: match.instance.tag
        )
    }

    /// Pair from a pasted pairing link (the QR payload another Mac shows).
    public func pair(link rawLink: String) async -> HivePairOutcome {
        let scope = await scopeProvider()
        switch linkDecoder.decode(rawLink, currentStackUserID: scope.stackUserID) {
        case .invalidLink:
            return .invalidLink
        case .loopbackRejected:
            return .loopbackRejected
        case .accountMismatch:
            return .accountMismatch
        case .ticket(let ticket):
            // The v2 pairing grammar deliberately carries no device id or
            // display name (identity arrives post-handshake from
            // `mobile.host.status`), so mirror the iOS manual-host flow: pair
            // under a synthetic id derived from the dialable endpoint and let
            // the first connection adopt the host-reported identity.
            let macDeviceID: String
            if ticket.macDeviceID.isEmpty {
                guard let synthesized = Self.syntheticDeviceID(for: ticket.routes) else {
                    return .invalidLink
                }
                macDeviceID = synthesized
            } else {
                macDeviceID = ticket.macDeviceID
            }
            guard macDeviceID != ownDeviceID else { return .loopbackRejected }
            return await persistPairing(
                macDeviceID: macDeviceID,
                displayName: ticket.macDisplayName ?? Self.endpointLabel(for: ticket.routes),
                routes: ticket.routes,
                instanceTag: nil
            )
        }
    }

    /// The iOS-compatible synthetic identity for a link that names no device:
    /// `manual-<host>:<port>` from the first dialable route.
    static func syntheticDeviceID(for routes: [CmxAttachRoute]) -> String? {
        endpointLabel(for: routes).map { "manual-\($0)" }
    }

    private static func endpointLabel(for routes: [CmxAttachRoute]) -> String? {
        for route in routes {
            if case let .hostPort(host, port) = route.endpoint {
                return "\(host):\(port)"
            }
        }
        return nil
    }

    /// Remove the local pairing record for a computer. Registry rows remain
    /// visible; only the pairing (persisted routes) is forgotten.
    /// - Returns: `true` when the store accepted the removal.
    @discardableResult
    public func unpair(deviceID: String) async -> Bool {
        let scope = await scopeProvider()
        do {
            try await pairedStore.remove(
                macDeviceID: deviceID,
                stackUserID: scope.stackUserID,
                teamID: scope.teamID
            )
        } catch {
            return false
        }
        await reloadPairedRecords(scope: scope)
        rebuild()
        return true
    }

    private func persistPairing(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?
    ) async -> HivePairOutcome {
        guard !routes.isEmpty else { return .noRoutes }
        let scope = await scopeProvider()
        do {
            try await pairedStore.upsert(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                instanceTag: instanceTag,
                markActive: false,
                stackUserID: scope.stackUserID,
                teamID: scope.teamID,
                now: now()
            )
        } catch {
            return .storeFailed
        }
        await reloadPairedRecords(scope: scope)
        rebuild()
        return .paired(deviceID: macDeviceID)
    }

    // MARK: - Presence

    private func startPresenceIfNeeded() {
        guard presenceTask == nil, let presence else { return }
        presenceTask = Task { [weak self] in
            await self?.runPresenceLoop(presence: presence)
        }
    }

    private func runPresenceLoop(presence: any PresenceSubscribing) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                let stream = try await presence.subscribe()
                for try await update in stream {
                    consecutiveFailures = 0
                    presenceMap.apply(update)
                    rebuild()
                }
            } catch {
                consecutiveFailures += 1
            }
            if Task.isCancelled { return }
            // The presence stream ended (server deadline) or failed; the
            // injected delay bounds the resubscribe backoff and is cancelled
            // with this task.
            await presenceRetryDelay(consecutiveFailures)
        }
    }

    // MARK: - Merge

    private func rebuild() {
        computers = Self.mergedComputers(
            registry: registryDevices,
            paired: pairedRecords,
            presence: presenceMap,
            ownDeviceID: ownDeviceID
        )
        for (_, continuation) in listeners {
            continuation.yield(computers)
        }
    }

    /// Pure merge of the three sources into sorted rows. Exposed for tests.
    public static func mergedComputers(
        registry: [RegistryDevice],
        paired: [MobilePairedMac],
        presence: PresenceMap,
        ownDeviceID: String
    ) -> [HiveComputer] {
        let pairedByID = Dictionary(uniqueKeysWithValues: paired.map { ($0.macDeviceID, $0) })
        var rows: [HiveComputer] = registry.map { device in
            let record = pairedByID[device.deviceId]
            return HiveComputer(
                deviceID: device.deviceId,
                displayName: record?.customName?.nonEmpty
                    ?? device.displayName?.nonEmpty
                    ?? record?.displayName?.nonEmpty
                    ?? String(device.deviceId.prefix(8)),
                platform: device.platform,
                isThisComputer: device.deviceId == ownDeviceID,
                isPaired: record != nil,
                presence: Self.presenceState(
                    for: device.deviceId,
                    presence: presence,
                    fallbackLastSeen: device.lastSeenAt
                ),
                buildLabel: presence.deviceSummary(deviceId: device.deviceId)?.buildLabel,
                instances: device.instances.map { instance in
                    HiveComputerInstance(
                        tag: instance.tag,
                        routes: instance.routes,
                        lastSeenAt: presence.instanceSummary(
                            deviceId: device.deviceId,
                            tag: instance.tag
                        ).map { max($0.lastSeenAt, instance.lastSeenAt) } ?? instance.lastSeenAt,
                        isOnline: presence.instanceSummary(
                            deviceId: device.deviceId,
                            tag: instance.tag
                        )?.online ?? false
                    )
                }
            )
        }
        let registryIDs = Set(registry.map(\.deviceId))
        for record in paired where !registryIDs.contains(record.macDeviceID) {
            rows.append(
                HiveComputer(
                    deviceID: record.macDeviceID,
                    displayName: record.resolvedName,
                    platform: nil,
                    isThisComputer: record.macDeviceID == ownDeviceID,
                    isPaired: true,
                    presence: Self.presenceState(
                        for: record.macDeviceID,
                        presence: presence,
                        fallbackLastSeen: record.lastSeenAt
                    ),
                    buildLabel: presence.deviceSummary(deviceId: record.macDeviceID)?.buildLabel,
                    instances: [
                        HiveComputerInstance(
                            tag: record.instanceTag ?? "default",
                            routes: record.routes,
                            lastSeenAt: record.lastSeenAt,
                            isOnline: false
                        )
                    ]
                )
            )
        }
        return rows.sorted { lhs, rhs in
            if lhs.isThisComputer != rhs.isThisComputer { return lhs.isThisComputer }
            if lhs.presence.isOnline != rhs.presence.isOnline { return lhs.presence.isOnline }
            let lhsSeen = lhs.presence.lastSeenAt ?? .distantPast
            let rhsSeen = rhs.presence.lastSeenAt ?? .distantPast
            if lhs.presence.isOnline == rhs.presence.isOnline, lhsSeen != rhsSeen {
                return lhsSeen > rhsSeen
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func presenceState(
        for deviceID: String,
        presence: PresenceMap,
        fallbackLastSeen: Date?
    ) -> HiveComputerPresence {
        guard let summary = presence.deviceSummary(deviceId: deviceID) else {
            return .unknown(lastSeenAt: fallbackLastSeen)
        }
        if summary.online { return .online }
        let lastSeen = [summary.lastSeenAt, fallbackLastSeen]
            .compactMap { $0 }
            .max()
        return .offline(lastSeenAt: lastSeen)
    }
}

extension String {
    /// The string itself when non-empty after trimming, else `nil`; merge
    /// helper for picking the first usable display name.
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
