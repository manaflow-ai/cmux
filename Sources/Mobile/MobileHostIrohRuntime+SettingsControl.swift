import CMUXMobileCore
import CmuxIrohTransport
import Foundation

@MainActor
extension MobileHostIrohRuntime: CmxIrohSettingsControlling {
    func setIrohPathPreference(_ preference: CmxIrohPathPreference) async throws {
        let hadStoredChange = CmxIrohPathPreference.stored(in: .standard) != preference
        let hadEffectiveChange = transportVerificationMode != preference.transportVerificationMode
        UserDefaults.standard.set(
            preference.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        #if DEBUG
        UserDefaults.standard.removeObject(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        UserDefaults.standard.removeObject(forKey: Self.debugRelayOnlyDefaultsKey)
        #endif
        guard hadStoredChange || hadEffectiveChange else { return }
        publishIrohSettingsUpdate()
        await scheduleReconcile(
            eraseAccountState: false,
            restartActiveRuntime: true
        ).value
    }

    func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            irohSettingsContinuations[id] = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                continuation.yield(await self.irohSettingsSnapshot())
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.irohSettingsContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func setIrohRelayPreference(
        _ preference: CmxIrohRelayPreferenceDraft
    ) async throws {
        let validated = try preference.validated()
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        let mapped: CmxIrohAccountRelayPreference
        switch validated {
        case .automatic:
            mapped = .automatic
        case let .managed(ids):
            mapped = .managed(ids)
        case .custom:
            guard !current.customRelays.isEmpty else {
                throw SettingsError.incompleteCustomRelay
            }
            mapped = .custom(current.customRelays)
        }
        let effective = try await context.service.setConfiguration(
            current.updatingActivePreference(mapped),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: Date()
        )
        try await applyRelayPolicy(effective)
        await refreshRelayPolicyAfterMutation(context)
    }

    func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws {
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        var definitions = current.customRelays
        let requestedID = relay.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (requestedID?.isEmpty == false ? requestedID : nil)?
            .lowercased() ?? UUID().uuidString.lowercased()
        let existingIndex = definitions.firstIndex(where: { $0.id == id })
        let existingDefinition = existingIndex.map { definitions[$0] }
        if relay.authMode == .deviceSecret,
           existingDefinition?.authMode != .staticToken,
           deviceSecret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw SettingsError.incompleteCustomRelay
        }
        let displayName = relay.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = try CmxIrohCustomRelayDefinition(
            id: id,
            url: Self.canonicalRelayURL(relay.url),
            provider: relay.provider.trimmingCharacters(in: .whitespacesAndNewlines),
            region: relay.region.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.isEmpty ? nil : displayName,
            authMode: relay.authMode == .deviceSecret ? .staticToken : .none
        )
        if let existingIndex {
            definitions[existingIndex] = definition
        } else {
            definitions.append(definition)
        }
        var effective = try await context.service.setConfiguration(
            current.replacingCustomRelays(definitions),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: Date()
        )
        try await applyRelayPolicy(effective)
        if definition.authMode == .staticToken, let deviceSecret {
            effective = try await context.service.setStaticCredential(
                deviceSecret,
                relayID: definition.id,
                relayURL: definition.url,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: Date()
            )
            try await applyRelayPolicy(effective)
        }
        await refreshRelayPolicyAfterMutation(context)
    }

    func removeIrohCustomRelay(id: String) async throws {
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        guard current.customRelays.contains(where: { $0.id == id }) else {
            throw SettingsError.missingCustomRelay
        }
        let remaining = current.customRelays.filter { $0.id != id }
        let effective = try await context.service.setConfiguration(
            current.replacingCustomRelays(remaining),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: Date()
        )
        try await applyRelayPolicy(effective)
        await refreshRelayPolicyAfterMutation(context)
    }

    func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult {
        guard let effective = await relayPolicyService?.effectivePolicy(),
              let definition = effective.requestedConfiguration?.customRelays.first(where: {
                  $0.id == id
              }),
              !effective.missingCredentialRelayIDs.contains(id) else {
            return .incomplete
        }
        // A provider may bind its device secret to the live endpoint identity.
        // A throwaway endpoint would then produce a misleading false failure.
        guard definition.authMode == .none,
              let relay = try? CmxIrohCustomRelay(url: definition.url),
              let profile = try? CmxIrohCustomRelayProfile(relays: [relay]) else {
            return .incomplete
        }
        switch await CmxIrohCustomRelayProbe().probe(
            profile: CmxIrohEndpointRelayProfile(customProfile: profile)
        ) {
        case .reachable:
            return .reachable(latencyMilliseconds: nil)
        case .invalidProfile, .bindFailed, .endpointClosed, .timedOut:
            return .failed
        }
    }

    func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        await refreshIrohSettings()
        let snapshot = await irohSettingsSnapshot()
        let diagnostics = await irohDiagnosticReport()
        let relayReachability: CmxIrohConnectionCheckReport.RelayReachability
        if transportVerificationMode == .directOnly {
            // Relays are administratively excluded by the transport mode; a
            // failed relay probe here must not send users to corporate IT.
            relayReachability = .notConfigured
        } else if let profile = await relayPolicyService?.effectivePolicy()?.endpointRelayProfile,
                  !profile.allowedRelayURLs.isEmpty {
            if let isReachable = await runtime?.hasReachableRelay(in: profile.allowedRelayURLs) {
                relayReachability = isReachable ? .reachable : .unreachable
            } else {
                relayReachability = .unavailable
            }
        } else {
            relayReachability = .notConfigured
        }
        return CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot,
            diagnostics: diagnostics,
            relayReachability: relayReachability
        )
    }

    func refreshIrohSettings() async {
        guard let context = try? relaySettingsContext() else {
            publishIrohSettingsUpdate()
            return
        }
        diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshStarted))
        do {
            let effective = try await context.service.refresh(
                endpointID: context.endpointID,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: Date()
            )
            try await applyRelayPolicy(effective)
            diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
        } catch {
            diagnosticLog.record(DiagnosticEvent(
                .relayPolicyRefreshFailed,
                b: Self.diagnosticFailureKind(for: error).rawValue
            ))
            relayPolicyDiagnostics = await context.service.diagnosticsSnapshot()
            publishIrohSettingsUpdate()
        }
    }

    func irohDiagnosticReport() async -> DiagnosticReport {
        await diagnosticLog.snapshot()
    }

    func exportIrohDiagnosticReport() async -> Data {
        await diagnosticLog.export()
    }

    func clearIrohDiagnosticReport() async {
        await diagnosticLog.clear()
        publishIrohSettingsUpdate()
    }

    func observeRelayPolicyDiagnostics(
        service: CmxIrohRelayPolicyService?,
        accountID: String,
        revision: UInt64
    ) {
        relayPolicyObservationTask?.cancel()
        guard let service else { return }
        relayPolicyObservationTask = Task { @MainActor [weak self] in
            let snapshots = await service.diagnosticsSnapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled,
                      let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID else { return }
                self.relayPolicyDiagnostics = snapshot
                self.relayPolicyEffective = await service.effectivePolicy()
                self.publishIrohSettingsUpdate()
            }
        }
    }

    func observeSelectedPathChanges(
        runtime: CmxIrohHostRuntime,
        accountID: String,
        revision: UInt64
    ) {
        selectedPathObservationTask?.cancel()
        selectedPathObservationTask = Task { @MainActor [weak self] in
            let changes = await runtime.selectedTransportPathChanges()
            for await _ in changes {
                guard !Task.isCancelled,
                      let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.runtime === runtime else { return }
                let selectedPath = await runtime.selectedTransportPath(
                    relayPolicy: self.relayPolicyEffective
                )
                self.diagnosticLog.record(DiagnosticEvent(
                    .selectedPathChanged,
                    a: DiagnosticPathKind(selectedPath).rawValue
                ))
                self.publishIrohSettingsUpdate()
            }
        }
    }

    /// Refreshes the signed relay catalog before expiry and removes relay
    /// authority at expiry when the broker remains unavailable. The live Iroh
    /// endpoint and authenticated sessions stay intact, so direct paths remain
    /// usable while a later retry can restore relay service.
    func scheduleRelayPolicyRefresh(
        service: CmxIrohRelayPolicyService?,
        accountID: String,
        endpointID: CmxIrohPeerIdentity,
        trustRoot: CmxIrohRelayPolicyTrustRoot?,
        revision: UInt64,
        refreshImmediately: Bool
    ) {
        relayPolicyRefreshTask?.cancel()
        relayPolicyRefreshTask = nil
        relayPolicyRefreshTaskID = nil
        guard let service, let trustRoot else {
            relayPolicyRefreshService = nil
            relayPolicyRefreshAccountID = nil
            relayPolicyRefreshEndpointID = nil
            relayPolicyRefreshTrustRoot = nil
            relayPolicyRefreshRevision = nil
            return
        }
        relayPolicyRefreshService = service
        relayPolicyRefreshAccountID = accountID
        relayPolicyRefreshEndpointID = endpointID
        relayPolicyRefreshTrustRoot = trustRoot
        relayPolicyRefreshRevision = revision
        let taskID = UUID()
        relayPolicyRefreshTaskID = taskID
        relayPolicyRefreshTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.relayPolicyRefreshTaskID == taskID {
                    self.relayPolicyRefreshTask = nil
                    self.relayPolicyRefreshTaskID = nil
                }
            }
            var retryAt: Date?
            var failureCount = 0
            var relayAuthorityExpired = false
            var shouldRefreshImmediately = refreshImmediately
            while !Task.isCancelled {
                guard let self,
                      self.ownsRelayPolicyRefresh(
                          taskID: taskID,
                          service: service,
                          accountID: accountID,
                          revision: revision
                      ),
                      self.relayPolicyNetworkReachable == true else { return }
                let snapshot = await service.diagnosticsSnapshot()
                let clock = self.relayPolicyRefreshClock
                let current = clock.now()
                let attemptAt: Date
                if shouldRefreshImmediately {
                    attemptAt = current
                    shouldRefreshImmediately = false
                } else {
                    attemptAt = Self.relayPolicyRefreshAttemptDate(
                        policyExpiresAt: relayAuthorityExpired
                            ? nil
                            : snapshot.policyExpiresAt,
                        retryAt: retryAt,
                        now: current
                    )
                }
                let delay = attemptAt.timeIntervalSince(current)
                if delay > 0 {
                    do {
                        // This is the bounded retry deadline itself, not a
                        // polling/settling sleep. Reachability transitions
                        // cancel it and own the immediate recovery wake.
                        try await clock.sleep(until: attemptAt)
                    } catch {
                        return
                    }
                }
                let wakeDate = clock.now()
                guard !Task.isCancelled,
                      self.ownsRelayPolicyRefresh(
                          taskID: taskID,
                          service: service,
                          accountID: accountID,
                          revision: revision
                      ),
                      self.relayPolicyNetworkReachable == true else { return }
                if let retryAt,
                   retryAt > wakeDate,
                   Self.shouldDeactivateRelayPolicy(
                       policyExpiresAt: snapshot.policyExpiresAt,
                       now: wakeDate
                   ) {
                    let expired = await service.restore(
                        accountID: accountID,
                        trustRoot: trustRoot,
                        now: wakeDate
                    )
                    do {
                        let didApply = try await self.applyRelayPolicy(
                            expired,
                            refreshTaskID: taskID
                        )
                        guard didApply else { return }
                        guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                        relayAuthorityExpired = true
                    } catch {
                        // Keep the next already-armed retry deadline. The
                        // stale-policy marker is set only after the runtime
                        // accepts the replacement.
                        guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                    }
                    continue
                }
                self.diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshStarted))
                do {
                    let effective = try await service.refresh(
                        endpointID: endpointID,
                        accountID: accountID,
                        trustRoot: trustRoot,
                        now: clock.now()
                    )
                    guard !Task.isCancelled,
                          self.ownsRelayPolicyRefresh(
                              taskID: taskID,
                              service: service,
                              accountID: accountID,
                              revision: revision
                          ),
                          self.relayPolicyNetworkReachable == true else { return }
                    let didApply = try await self.applyRelayPolicy(
                        effective,
                        refreshTaskID: taskID
                    )
                    guard didApply else { return }
                    guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                    retryAt = nil
                    failureCount = 0
                    relayAuthorityExpired = false
                    self.diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          self.ownsRelayPolicyRefresh(
                              taskID: taskID,
                              service: service,
                              accountID: accountID,
                              revision: revision
                          ) else { return }
                    let failureKind = Self.diagnosticFailureKind(for: error)
                    self.diagnosticLog.record(DiagnosticEvent(
                        .relayPolicyRefreshFailed,
                        b: failureKind.rawValue
                    ))
                    // An explicit offline classification, or a path observer
                    // that says the host is offline, parks this loop. The
                    // reachability callback owns the next wake, so no timer
                    // continues polling a captive portal or asleep laptop.
                    guard !Self.shouldPauseRelayPolicyRetry(
                        failure: failureKind,
                        networkReachable: self.relayPolicyNetworkReachable
                    ) else { return }
                    let failureDate = clock.now()
                    if Self.shouldDeactivateRelayPolicy(
                        policyExpiresAt: snapshot.policyExpiresAt,
                        now: failureDate
                    ) {
                        let expired = await service.restore(
                            accountID: accountID,
                            trustRoot: trustRoot,
                            now: failureDate
                        )
                        do {
                            let didApply = try await self.applyRelayPolicy(
                                expired,
                                refreshTaskID: taskID
                            )
                            guard didApply else { return }
                            guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                            relayAuthorityExpired = true
                        } catch {
                            // A failed live replacement must not be marked as
                            // expired authority; the common retry calculation
                            // below will try the broker again.
                            guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                        }
                    } else {
                        let diagnostics = await service.diagnosticsSnapshot()
                        guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                        self.relayPolicyDiagnostics = diagnostics
                        self.publishIrohSettingsUpdate()
                    }
                    let retryDelay = CmxIrohRetrySchedule(for: failureKind).delay(
                        failureCount: failureCount,
                        retryAfterSeconds: (error as? any CmxRetryAfterProviding)?
                            .retryAfterSeconds,
                        jitterUnitInterval: self.relayPolicyRetryJitter()
                    )
                    failureCount = min(failureCount + 1, 20)
                    retryAt = failureDate.addingTimeInterval(retryDelay)
                    self.diagnosticLog.record(DiagnosticEvent(
                        .retryScheduled,
                        ms: UInt32(clamping: Int(retryDelay * 1_000)),
                        a: DiagnosticTransportKind.iroh.rawValue
                    ))
                }
            }
        }
    }

    private func ownsRelayPolicyRefresh(
        taskID: UUID,
        service: CmxIrohRelayPolicyService,
        accountID: String,
        revision: UInt64
    ) -> Bool {
        relayPolicyRefreshTaskID == taskID
            && revision == lifecycleRevision
            && activeAccountID == accountID
            && relayPolicyService === service
    }

    /// Checks the stored refresh context after an awaited policy operation.
    private func ownsRelayPolicyRefreshTask(_ taskID: UUID) -> Bool {
        guard relayPolicyRefreshTaskID == taskID,
              relayPolicyRefreshRevision == lifecycleRevision,
              relayPolicyRefreshAccountID == activeAccountID,
              let refreshService = relayPolicyRefreshService,
              let currentService = relayPolicyService else { return false }
        return refreshService === currentService
    }

    /// Whether a failed broker round should park until a path transition.
    /// Reachability is fail-closed: `nil` parks the loop until the platform
    /// observer supplies an authoritative path state. An offline-classified
    /// failure on a usable path still receives the ordinary long backoff, so a
    /// captive portal cannot permanently stop future policy refreshes.
    nonisolated static func shouldPauseRelayPolicyRetry(
        failure _: DiagnosticFailureKind,
        networkReachable: Bool?
    ) -> Bool {
        networkReachable != true
    }

    nonisolated static func relayPolicyRefreshAttemptDate(
        policyExpiresAt: Date?,
        retryAt: Date?,
        now: Date
    ) -> Date {
        if let retryAt {
            // Once the cached authority is already expired, it is no longer
            // an earlier refresh deadline. Keep the armed retry backoff; using
            // the stale expiry here would turn every failed restore into an
            // immediate retry loop.
            guard let policyExpiresAt, policyExpiresAt > now else { return retryAt }
            return min(retryAt, policyExpiresAt)
        }
        if let policyExpiresAt {
            return policyExpiresAt.addingTimeInterval(-60)
        }
        return now.addingTimeInterval(CmxIrohRetrySchedule.macHostRelayPolicy.initialDelay)
    }

    nonisolated static func shouldDeactivateRelayPolicy(
        policyExpiresAt: Date?,
        now: Date
    ) -> Bool {
        guard let policyExpiresAt else { return false }
        return now >= policyExpiresAt
    }

    func publishIrohSettingsUpdate() {
        guard !irohSettingsContinuations.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.irohSettingsSnapshot()
            for continuation in self.irohSettingsContinuations.values {
                continuation.yield(snapshot)
            }
        }
    }

    private func relaySettingsContext() throws -> (
        service: CmxIrohRelayPolicyService,
        accountID: String,
        endpointID: CmxIrohPeerIdentity,
        trustRoot: CmxIrohRelayPolicyTrustRoot
    ) {
        guard let relayPolicyService,
              let activeAccountID,
              let relayPolicyEndpointID,
              let relayPolicyTrustRoot else { throw SettingsError.unavailable }
        return (
            relayPolicyService,
            activeAccountID,
            relayPolicyEndpointID,
            relayPolicyTrustRoot
        )
    }

    private func refreshRelayPolicyAfterMutation(
        _ context: (
            service: CmxIrohRelayPolicyService,
            accountID: String,
            endpointID: CmxIrohPeerIdentity,
            trustRoot: CmxIrohRelayPolicyTrustRoot
        )
    ) async {
        do {
            let effective = try await context.service.refresh(
                endpointID: context.endpointID,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: Date()
            )
            try await applyRelayPolicy(effective)
        } catch {
            relayPolicyDiagnostics = await context.service.diagnosticsSnapshot()
            publishIrohSettingsUpdate()
        }
    }

    /// Installs a policy, optionally fenced to one refresh-task generation.
    @discardableResult
    private func applyRelayPolicy(
        _ effective: CmxIrohEffectiveRelayPolicy,
        refreshTaskID: UUID? = nil
    ) async throws -> Bool {
        let diagnostics = await relayPolicyService?.diagnosticsSnapshot()
        if let refreshTaskID {
            guard ownsRelayPolicyRefreshTask(refreshTaskID),
                  relayPolicyNetworkReachable == true else { return false }
        }
        if let runtime {
            if let refreshTaskID {
                guard ownsRelayPolicyRefreshTask(refreshTaskID),
                      relayPolicyNetworkReachable == true else { return false }
            }
            try await runtime.replaceRelayPolicy(effective)
        }
        if let refreshTaskID {
            guard ownsRelayPolicyRefreshTask(refreshTaskID),
                  relayPolicyNetworkReachable == true else { return false }
        }
        relayPolicyEffective = effective
        relayPolicyDiagnostics = diagnostics
        publishIrohSettingsUpdate()
        return true
    }

    /// Cancels relay-policy observers and clears the account-scoped refresh
    /// context without discarding the platform's last reachability sample.
    func clearRelayPolicyRuntimeState() {
        relayPolicyObservationTask?.cancel()
        relayPolicyObservationTask = nil
        relayPolicyRefreshTask?.cancel()
        relayPolicyRefreshTask = nil
        relayPolicyRefreshTaskID = nil
        serverSignalRefreshTask?.cancel()
        serverSignalRefreshTask = nil
        serverSignalRefreshTaskID = nil
        serverSignalRefreshRevision = nil
        serverSignalPendingRevision = nil
        relayPolicyRefreshService = nil
        relayPolicyRefreshAccountID = nil
        relayPolicyRefreshEndpointID = nil
        relayPolicyRefreshTrustRoot = nil
        relayPolicyRefreshRevision = nil
        relayPolicyService = nil
        relayPolicyEffective = nil
        relayPolicyDiagnostics = nil
        relayPolicyEndpointID = nil
        publishIrohSettingsUpdate()
    }


    private nonisolated static func canonicalRelayURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.host = components.host?.lowercased()
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? trimmed
    }
}
