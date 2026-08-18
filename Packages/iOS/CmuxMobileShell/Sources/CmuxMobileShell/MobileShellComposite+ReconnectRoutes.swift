import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import os

private let reconnectRouteLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "MobileReconnectRoutes"
)

/// Readiness of the selected Tailscale connection method.
///
/// Keeping the load phase explicit prevents presentation code from treating a
/// not-yet-loaded authorization as either confirmed or missing.
public enum MobileTailscaleSetupStatus: Equatable, Sendable {
    case notSelected
    case loadingAuthorization
    case pairingRequired
    case authorized
}

/// Canonical identity for one locally authorized legacy Tailscale endpoint.
private nonisolated struct MobileTailscaleAuthorizationEndpoint:
    Hashable, Sendable
{
    let macDeviceID: String
    let host: String
    let port: Int

    init?(macDeviceID: String, route: CmxAttachRoute) {
        guard route.kind == .tailscale || route.kind == .tcp,
              case let .hostPort(host, port) = route.endpoint,
              let evidence = try? CmxLegacyTailscaleAuthorizationEvidence(
                  macDeviceID: macDeviceID,
                  host: host,
                  port: port
              ) else {
            return nil
        }
        self.macDeviceID = evidence.macDeviceID
        self.host = evidence.host
        self.port = evidence.port
    }
}

enum ReconnectRouteRefreshOutcome: Sendable {
    case refreshedRoutes([CmxAttachRoute])
    case inconclusive
}

struct ReconnectRefreshSnapshot: Sendable {
    private struct Authority: Hashable, Sendable {
        let deviceID: String
        let instanceTag: String?

        init(
            deviceID: String,
            instanceTag: String?,
            macInstanceTagAuthority: MobileMacInstanceTagAuthority
        ) {
            self.deviceID = deviceID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            self.instanceTag = macInstanceTagAuthority.normalize(instanceTag)
        }
    }

    private let pairedMacsByAuthority: [Authority: [MobilePairedMac]]
    private let registryRoutes: DeviceRegistryRouteIndex?
    private let macInstanceTagAuthority: MobileMacInstanceTagAuthority

    init(
        pairedMacs: [MobilePairedMac],
        registryDevices: [RegistryDevice]?,
        macInstanceTagAuthority: MobileMacInstanceTagAuthority =
            MobileMacInstanceTagAuthority()
    ) {
        self.macInstanceTagAuthority = macInstanceTagAuthority
        pairedMacsByAuthority = Dictionary(grouping: pairedMacs) {
            Authority(
                deviceID: $0.macDeviceID,
                instanceTag: $0.instanceTag,
                macInstanceTagAuthority: macInstanceTagAuthority
            )
        }
        registryRoutes = registryDevices.map {
            DeviceRegistryRouteIndex(
                devices: $0,
                macInstanceTagAuthority: macInstanceTagAuthority
            )
        }
    }

    func currentMac(for captured: MobilePairedMac) -> MobilePairedMac? {
        let matches = pairedMacsByAuthority[
            Authority(
                deviceID: captured.macDeviceID,
                instanceTag: captured.instanceTag,
                macInstanceTagAuthority: macInstanceTagAuthority
            )
        ] ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    func registryResolution(for captured: MobilePairedMac) -> DeviceRegistryRouteResolution? {
        registryRoutes?.resolve(
            macDeviceID: captured.macDeviceID,
            instanceTag: captured.instanceTag
        )
    }
}

@MainActor
extension MobileShellComposite {
    /// Resolves one immutable legacy capability for an exact host/port route.
    /// Fresh registry/manual routes cannot create this evidence; they must
    /// match a route retained by the local schema migration.
    static func legacyTailscaleAuthorizationEvidence(
        for route: CmxAttachRoute,
        macDeviceID: String,
        persistedRoutes: [CmxAttachRoute]
    ) -> CmxLegacyTailscaleAuthorizationEvidence? {
        guard route.kind == .tailscale || route.kind == .tcp,
              case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        for persistedRoute in persistedRoutes
            where persistedRoute.kind == .tailscale || persistedRoute.kind == .tcp {
            guard case let .hostPort(persistedHost, persistedPort) = persistedRoute.endpoint,
                  let evidence = try? CmxLegacyTailscaleAuthorizationEvidence(
                      macDeviceID: macDeviceID,
                      host: persistedHost,
                      port: persistedPort
                  ),
                  evidence.authorizes(
                      macDeviceID: macDeviceID,
                      host: host,
                      port: port
                  ) else {
                continue
            }
            return evidence
        }
        return nil
    }

    /// Whether any paired Mac retains a current route matching an exact local
    /// Tailscale grant. A grant for an old endpoint is not usable after the Mac
    /// changes address, so both route sets must still agree.
    nonisolated static func hasUsableTailscaleAuthorization(
        in macs: [MobilePairedMac]
    ) -> Bool {
        var authorizedEndpoints: Set<MobileTailscaleAuthorizationEndpoint> = []
        for mac in macs {
            for route in mac.legacyTailscaleRoutes ?? [] {
                if let endpoint = MobileTailscaleAuthorizationEndpoint(
                    macDeviceID: mac.macDeviceID,
                    route: route
                ) {
                    authorizedEndpoints.insert(endpoint)
                }
            }
        }
        guard !authorizedEndpoints.isEmpty else { return false }

        for mac in macs {
            for route in mac.routes {
                guard let endpoint = MobileTailscaleAuthorizationEndpoint(
                    macDeviceID: mac.macDeviceID,
                    route: route
                ) else {
                    continue
                }
                if authorizedEndpoints.contains(endpoint) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether Tailscale Only can dial an endpoint the user authorized locally.
    public var hasUsableTailscaleAuthorization: Bool {
        if connectionState == .connected,
           remoteClient?.usesLocallyAuthorizedTailscaleRoute == true {
            return true
        }
        return hasStoredUsableTailscaleAuthorization
    }

    /// Readiness if the user selects Tailscale, before that preference is saved.
    public var tailscaleSetupStatusWhenSelected: MobileTailscaleSetupStatus {
        if hasUsableTailscaleAuthorization {
            return .authorized
        }
        if pairedMacLoadState == .notLoaded, hasKnownPairedMac {
            return .loadingAuthorization
        }
        return .pairingRequired
    }

    /// Readiness of the currently selected Tailscale connection method.
    public var tailscaleSetupStatus: MobileTailscaleSetupStatus {
        guard connectionMethodStore?.method == .tailscale else {
            return .notSelected
        }
        return tailscaleSetupStatusWhenSelected
    }

    /// Whether the selected Tailscale method still needs its one-time pairing grant.
    public var tailscalePairingRequired: Bool {
        tailscaleSetupStatus == .pairingRequired
    }

    /// The strict Tailscale policy for one paired Mac: only exact grant routes
    /// remain dialable while the user has selected Tailscale.
    struct TailscaleRouteRequirement {
        let macDeviceID: String
        let grantRoutes: [CmxAttachRoute]
    }

    /// Supported routes for reconnecting an already-paired Mac.
    ///
    /// Historical host/port records retain their persisted label until the
    /// transport factory boundary. Native peer and URL routes are discarded
    /// before selection or RPC admission, so a reconnect cannot revive a
    /// removed provider.
    static func storedReconnectRoutes(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false,
        tailscaleRequirement: TailscaleRouteRequirement? = nil
    ) -> [CmxAttachRoute] {
        let supportedKinds = Set(supportedKinds)
        let acceptsLegacyHostPort = supportedKinds.isEmpty
            || supportedKinds.contains(.tcp)
            || supportedKinds.contains(.tailscale)
        var seenIDs = Set<String>()
        var seenEndpoints = Set<String>()
        let ordered = routes.compactMap { route -> CmxAttachRoute? in
            guard route.usesStableTCPTransport,
                  ((route.kind == .tcp || route.kind == .tailscale)
                      && acceptsLegacyHostPort
                      || supportedKinds.contains(route.kind)),
                  seenIDs.insert(route.id).inserted,
                  case let .hostPort(host, port) = route.endpoint else {
                return nil
            }
            guard seenEndpoints.insert("\(host)\u{1F}\(port)").inserted else {
                return nil
            }
            return route
        }.sorted(by: Self.routeSortsBefore)
        var selected = ordered
        if let tailscaleRequirement {
            selected = selected.filter { route in
                legacyTailscaleAuthorizationEvidence(
                    for: route,
                    macDeviceID: tailscaleRequirement.macDeviceID,
                    persistedRoutes: tailscaleRequirement.grantRoutes
                ) != nil
            }
        }
        if preferNonLoopback {
            selected.removeAll { $0.kind == .debugLoopback }
        }
        return selected
    }

    /// The dial order for one stored Mac, honoring the user's connection-method
    /// choice. With the default automatic method this is exactly
    /// ``storedReconnectRoutes(_:supportedKinds:preferNonLoopback:tailscaleRequirement:)``
    /// without a preference.
    func orderedReconnectRoutes(
        for mac: MobilePairedMac,
        supportedKinds: [CmxAttachTransportKind]
    ) -> [CmxAttachRoute] {
        Self.storedReconnectRoutes(
            mac.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes,
            tailscaleRequirement: connectionMethodStore?.method == .tailscale
                ? TailscaleRouteRequirement(
                    macDeviceID: mac.macDeviceID,
                    grantRoutes: mac.legacyTailscaleRoutes ?? []
                )
                : nil
        )
    }

    /// Refresh the active row only while its account, device, and authenticated
    /// instance authority still match the values captured before the network call.
    func refreshRoutesFromRegistry(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) {
        guard let deviceRegistry, let pairedMacStore else { return }
        let macDeviceID = mac.macDeviceID
        let localRoutes = mac.routes
        let displayName = mac.displayName
        let capturedInstanceTag = mac.instanceTag
        let task = Task { [weak self] in
            let registryRoutes = await deviceRegistry.freshRoutes(
                forMacDeviceID: macDeviceID,
                instanceTag: capturedInstanceTag
            )
            guard let updated = DeviceRegistryService.selectReconnectRoutes(
                local: localRoutes,
                registry: registryRoutes
            ), let self else { return }
            await self.performSerializedPairedMacWrite(ifStillCurrent: nil) {
                guard await self.isScopeCurrent(scope),
                      await !self.isHiddenMacDeviceID(
                        macDeviceID,
                        instanceTag: capturedInstanceTag,
                        scope: scope
                      ) else { return }
                let activeMac: MobilePairedMac?
                do {
                    activeMac = try await pairedMacStore.activeMac(
                        stackUserID: scope.userID,
                        teamID: scope.teamID
                    )
                } catch {
                    reconnectRouteLog.debug("registry refresh recheck failed: \(String(describing: error), privacy: .public)")
                    return
                }
                guard await self.isScopeCurrent(scope),
                      await !self.isHiddenMacDeviceID(
                        macDeviceID,
                        instanceTag: capturedInstanceTag,
                        scope: scope
                      ),
                      DeviceRegistryService.shouldApplyRegistryRefresh(
                        isSignedIn: self.isSignedIn,
                        capturedUserID: scope.userID,
                        currentUserID: self.identityProvider?.currentUserID ?? scope.userID,
                        activeMacID: activeMac?.macDeviceID,
                        activeMacInstanceTag: activeMac?.instanceTag,
                        targetMacID: macDeviceID,
                        targetInstanceTag: capturedInstanceTag
                ) else { return }
                do {
                    let wrote = try await pairedMacStore.upsertRoutesIfAuthorized(
                        macDeviceID: macDeviceID,
                        displayName: displayName,
                        routes: updated,
                        condition: .matchingInstanceTag(capturedInstanceTag),
                        markActive: nil,
                        stackUserID: scope.userID,
                        teamID: scope.teamID,
                        now: Date()
                    )
                    guard wrote else { return }
                } catch {
                    reconnectRouteLog.debug("registry refresh upsert failed: \(String(describing: error), privacy: .public)")
                    return
                }
                if await self.isHiddenMacDeviceID(
                    macDeviceID,
                    instanceTag: capturedInstanceTag,
                    scope: scope
                ) {
                    try? await pairedMacStore.remove(
                        macDeviceID: macDeviceID,
                        instanceTag: capturedInstanceTag,
                        stackUserID: scope.userID,
                        teamID: scope.teamID
                    )
                    return
                }
                if await self.isScopeCurrent(scope) { await self.loadPairedMacs() }
            }
        }
        registryRouteRefreshTask = task
    }

    /// The first reachable host/port route to a Mac, in priority order.
    ///
    /// When `preferNonLoopback` is set (physical devices), a real route
    /// (`.tailscale` etc.) is always chosen over a `.debugLoopback` route even
    /// if the loopback route has a lower (more-preferred) priority, because a
    /// loopback route can never reach a remote Mac from a physical phone. A
    /// loopback route is used only when it is the sole supported route — the
    /// on-device XCUITest mock host, which serves a real listener on `127.0.0.1`
    /// inside the test runner.
    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> (String, Int)? {
        reconnectHostPortRoutes(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ).first.map { ($0.host, $0.port) }
    }

    /// Resume foreground-only refresh loops after the app becomes active.
    public func resumeForegroundRefresh() {
        guard foregroundRefreshLifecycleState != .active else { return }
        foregroundRefreshLifecycleState = .active
        foregroundRefreshIsActive = true
        foregroundResumeEpoch &+= 1
        startObservingNetworkPathChanges()
        // Covers stores constructed already-signed-in (no isSignedIn edge) and
        // restarts a subscription torn down while backgrounded.
        evaluatePresenceSubscription()
        let shouldResync = shouldResyncTerminalOutputOnForeground()
        lastBackgroundedAt = nil
        // Persisted connections let the recovery owner probe first. Restarting
        // their listener here can make a dead MobileCoreRPCClient reopen its old
        // transport before the probe decides to replace it, creating two owners
        // for one foreground transition. Preview/legacy clients have no stored
        // route to redial, so retain their same-client resubscribe fallback.
        if shouldResync, pairedMacStore == nil {
            resyncTerminalOutput(reason: "foreground", restartEventStream: true)
        }
        restartActiveMobileBrowserStreams()
        restartActiveMobileSimulatorStreams()
        recoverForegroundConnectionIfNeeded(resyncAfterHealthy: shouldResync)
        recoverDisconnectedOnForegroundIfNeeded()
        recoverPendingInactiveRecoveryIfNeeded()
        resumeSecondaryControlMaintenanceAfterForeground()
        // The foreground Mac's workspace list updates live over the sync stream,
        // but the other Macs are a read-only snapshot. Re-aggregate them on
        // foreground so workspaces created on another Mac while backgrounded
        // appear without a manual pull-to-refresh.
        if multiMacAggregationEnabled,
           connectionState == .connected,
           remoteClient != nil {
            self.scheduleSecondaryAggregation()
        }
    }

    /// Record that the app entered the background. Transient inactive phases
    /// must not call this: they do not suspend the process and canceling a
    /// useful recovery there makes wake latency depend on interruption churn.
    public func suspendForegroundRefresh() {
        guard foregroundRefreshLifecycleState != .background else { return }
        foregroundRefreshLifecycleState = .background
        foregroundRefreshIsActive = false
        if connectionRecoveryOwner.cancelProbing() {
            applyConnectionRecoveryOwnerState()
        }
        suspendSecondaryConnectionEstablishmentForBackground()
        guard lastBackgroundedAt == nil else { return }
        lastBackgroundedAt = runtime?.now() ?? Date()
        stopActiveMobileBrowserStreamsForBackground()
        stopActiveMobileSimulatorStreamsForBackground()
    }

    /// A foreground return while disconnected redials the stored Mac
    /// immediately. Covers a recovery that failed while the app was
    /// backgrounded (its deadline burns during suspension): without this
    /// the user sits on "Connection lost" until a network change, presence
    /// push, or backoff timer fires. Gated on a finished startup reconnect
    /// so it cannot race the launch path, and excluded for reauth-required
    /// states where a redial cannot help.
    func recoverDisconnectedOnForegroundIfNeeded() {
        guard connectionState != .connected,
              isSignedIn,
              pairedMacStore != nil,
              !connectionRequiresReauth,
              !isReconnectingStoredMac,
              didFinishStoredMacReconnectAttempt,
              !connectionRecoveryOwner.isActive else {
            return
        }
        recoverMobileConnection(trigger: .foreground)
    }

    func loadReconnectRefreshSnapshot(
        scope: MobileShellScopeSnapshot
    ) async -> ReconnectRefreshSnapshot? {
        guard await isScopeCurrent(scope) else { return nil }
        let registryDevices: [RegistryDevice]?
        if let deviceRegistry {
            switch await deviceRegistry.listDevices() {
            case .ok(let devices):
                registryDevices = devices
            case .authRejected, .transientFailure:
                registryDevices = nil
            }
        } else {
            registryDevices = nil
        }
        guard await isScopeCurrent(scope),
              let pairedMacStore,
              let pairedMacs = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID,
                  teamID: scope.teamID
              ),
              await isScopeCurrent(scope) else {
            return nil
        }
        return ReconnectRefreshSnapshot(
            pairedMacs: pairedMacs,
            registryDevices: registryDevices,
            macInstanceTagAuthority: macInstanceTagAuthority
        )
    }

    /// Re-read one exact account/device/instance row immediately before
    /// presenting legacy-Mac migration guidance. A registry snapshot can become
    /// stale while Presence persists a replacement route, so only the current paired
    /// store may authorize that user-facing conclusion.
    func isCurrentLegacyPrivateNetworkPairing(
        _ captured: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard await isScopeCurrent(scope),
              let pairedMacStore,
              let pairedMacs = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID,
                  teamID: scope.teamID
              ),
              await isScopeCurrent(scope),
              let currentMac = ReconnectRefreshSnapshot(
                  pairedMacs: pairedMacs,
                  registryDevices: nil,
                  macInstanceTagAuthority: macInstanceTagAuthority
              ).currentMac(for: captured),
              await !isHiddenMacDeviceID(
                  captured.macDeviceID,
                  instanceTag: captured.instanceTag,
                  scope: scope
              ) else {
            return false
        }
        return currentMac.routes.contains(where: { $0.usesStableTCPTransport })
    }

    func freshReconnectRoutesAfterLocalFailure(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot,
        snapshot: ReconnectRefreshSnapshot?
    ) async -> ReconnectRouteRefreshOutcome {
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let snapshot,
              await isScopeCurrent(scope),
              await !isHiddenMacDeviceID(
                  mac.macDeviceID,
                  instanceTag: mac.instanceTag,
                  scope: scope
              ),
              let currentMac = snapshot.currentMac(for: mac),
              await isScopeCurrent(scope),
              await !isHiddenMacDeviceID(
                  mac.macDeviceID,
                  instanceTag: mac.instanceTag,
                  scope: scope
              ) else {
            return .inconclusive
        }
        // Presence may authorize and persist the same registry routes while the
        // list request is in flight. That current row is newer than the captured
        // candidate and is already scoped to this account/device/instance, so use
        // it directly instead of mistaking registry equality for "no route."
        if currentMac.routes != mac.routes {
            let reconnectRoutes = Self.storedReconnectRoutes(
                currentMac.routes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            )
            if !reconnectRoutes.isEmpty {
                return .refreshedRoutes(reconnectRoutes)
            }
        }

        guard case .unique(let registryRoutes) = snapshot.registryResolution(for: mac) else {
            return .inconclusive
        }
        guard let updatedRoutes = DeviceRegistryService.selectReconnectRoutes(
            local: currentMac.routes,
            registry: registryRoutes
        ) else {
            return .inconclusive
        }
        let reconnectRoutes = Self.storedReconnectRoutes(
            updatedRoutes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        if !reconnectRoutes.isEmpty {
            return .refreshedRoutes(reconnectRoutes)
        }
        return .inconclusive
    }

    func shouldResyncTerminalOutputOnForeground() -> Bool {
        guard connectionState == .connected,
              remoteClient != nil,
              terminalEventListenerTask != nil,
              let lastBackgroundedAt else {
            return true
        }
        let now = runtime?.now() ?? Date()
        guard now.timeIntervalSince(lastBackgroundedAt) < Self.foregroundResyncShortBackgroundThreshold else {
            return true
        }
        let last = lastTerminalEventAt ?? now
        return now.timeIntervalSince(last) >= Self.renderGridLivenessSilenceThreshold
    }

    /// Writes the persisted paired-Mac hint only when `generation` is current.
    func setHasKnownPairedMac(_ value: Bool, generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        hasKnownPairedMac = value
    }

    /// Finish the stored-Mac reconnect attempt and drain any forced retry that
    /// arrived while the underlying dial was still in flight.
    func finishStoredMacReconnectAttempt(generation: Int, supersede: Bool = false) {
        guard supersede || generation == storedMacReconnectGeneration else { return }
        if supersede { storedMacReconnectGeneration &+= 1 }
        let shouldRetry = pendingForcedStoredMacReconnect
        pendingForcedStoredMacReconnect = false
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = true
        guard shouldRetry, isSignedIn else { return }
        let stackUserID = lastReconnectStackUserID
        let accountID = stackUserID ?? identityProvider?.currentUserID
        let retryGeneration = storedMacReconnectGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard retryGeneration == self.storedMacReconnectGeneration,
                  self.isSignedIn,
                  self.identityProvider?.currentUserID == accountID else { return }
            _ = await self.retryActiveMacReconnect(
                stackUserID: stackUserID,
                force: true
            )
        }
    }

    /// Returns the completed result when an async stored reconnect must stop.
    /// A newer generation owns the work (`false`); an already-live foreground
    /// client satisfies the request without another dial (`true`).
    func storedMacReconnectInterruptionResult(generation: Int) -> Bool? {
        guard generation == storedMacReconnectGeneration else { return false }
        guard !hasActiveMacConnection else {
            finishStoredMacReconnectAttempt(generation: generation)
            return true
        }
        return nil
    }

    /// Ordered host/port reconnect candidates for a Mac, preserving the single-route
    /// preference policy but keeping fallbacks available for the same Mac.
    ///
    /// With `preferNonLoopback` (real physical devices) the list never contains
    /// a `.debugLoopback` route. Callers iterate every candidate, so keeping
    /// loopback as either a tail fallback or the sole route would dial the
    /// phone's own `127.0.0.1`, never the saved Mac. Explicit mock/simulator
    /// harnesses pass `false` and retain loopback for their in-process host.
    static func reconnectHostPortRoutes(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> [(host: String, port: Int, routeID: String)] {
        let supportedKinds = Set(supportedKinds)
        let acceptsLegacyHostPort = supportedKinds.isEmpty
            || supportedKinds.contains(.tcp)
            || supportedKinds.contains(.tailscale)
        let ordered = routes.compactMap { route -> CmxAttachRoute? in
            guard route.usesStableTCPTransport,
                  ((route.kind == .tcp || route.kind == .tailscale)
                      && acceptsLegacyHostPort
                      || supportedKinds.contains(route.kind)) else {
                return nil
            }
            return route
        }.sorted(by: Self.routeSortsBefore)
        var seenEndpoints = Set<String>()

        func appendCandidates(
            where predicate: (CmxAttachRoute) -> Bool,
            to candidates: inout [(host: String, port: Int, routeID: String)]
        ) {
            for route in ordered {
                guard predicate(route),
                      case let .hostPort(host, port) = route.endpoint else {
                    continue
                }
                let endpointKey = "\(host)\u{1F}\(port)"
                guard seenEndpoints.insert(endpointKey).inserted else { continue }
                candidates.append((host: host, port: port, routeID: route.id))
            }
        }

        var candidates: [(host: String, port: Int, routeID: String)] = []
        if preferNonLoopback {
            appendCandidates(where: { route in
                guard route.kind != .debugLoopback,
                      case let .hostPort(host, _) = route.endpoint else { return false }
                return Self.isIPLiteralHost(host)
            }, to: &candidates)
            appendCandidates(where: { $0.kind != .debugLoopback }, to: &candidates)
            return candidates
        }
        appendCandidates(where: { _ in true }, to: &candidates)
        return candidates
    }

    /// Merges a constrained reconnect ticket with the previously persisted route set.
    ///
    /// Constrained tickets prove only the dialed endpoint, not that other stored
    /// endpoints disappeared. Normalize legacy host/port records, drop removed
    /// provider routes, and deduplicate by route ID and endpoint.
    static func mergedReconnectRoutes(
        ticketRoutes: [CmxAttachRoute],
        storedRoutes: [CmxAttachRoute],
        at now: Date = Date()
    ) -> [CmxAttachRoute] {
        var merged: [CmxAttachRoute] = []
        var seenIDs = Set<String>()
        var seenEndpoints = Set<String>()

        func append(_ rawRoute: CmxAttachRoute) {
            guard rawRoute.usesStableTCPTransport,
                  let disclosed = rawRoute.disclosed(for: .authenticated, at: now),
                  seenIDs.insert(disclosed.id).inserted,
                  case let .hostPort(host, port) = disclosed.endpoint else {
                return
            }
            guard seenEndpoints.insert("\(host)\u{1F}\(port)").inserted else {
                return
            }
            merged.append(disclosed)
        }

        ticketRoutes.forEach(append)
        storedRoutes.forEach(append)
        return merged.sorted(by: Self.routeSortsBefore)
    }
}
