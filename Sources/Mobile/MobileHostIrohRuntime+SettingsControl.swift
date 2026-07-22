import CMUXMobileCore
import CmuxIrohTransport
import Foundation

@MainActor
extension MobileHostIrohRuntime: CmxIrohSettingsControlling {
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
        revision: UInt64
    ) {
        relayPolicyRefreshTask?.cancel()
        guard let service, let trustRoot else {
            relayPolicyRefreshTask = nil
            return
        }
        relayPolicyRefreshTask = Task { @MainActor [weak self] in
            var retryAt: Date?
            var failureCount = 0
            var relayAuthorityExpired = false
            while !Task.isCancelled {
                guard let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.relayPolicyService === service else { return }
                let snapshot = await service.diagnosticsSnapshot()
                let current = Date()
                let attemptAt = Self.relayPolicyRefreshAttemptDate(
                    policyExpiresAt: relayAuthorityExpired
                        ? nil
                        : snapshot.policyExpiresAt,
                    retryAt: retryAt,
                    now: current
                )
                let delay = attemptAt.timeIntervalSince(current)
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }
                let wakeDate = Date()
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
                    try? await self.applyRelayPolicy(expired)
                    relayAuthorityExpired = true
                    continue
                }
                guard !Task.isCancelled,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.relayPolicyService === service else { return }
                self.diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshStarted))
                do {
                    let effective = try await service.refresh(
                        endpointID: endpointID,
                        accountID: accountID,
                        trustRoot: trustRoot,
                        now: Date()
                    )
                    try await self.applyRelayPolicy(effective)
                    retryAt = nil
                    failureCount = 0
                    relayAuthorityExpired = false
                    self.diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
                } catch {
                    self.diagnosticLog.record(DiagnosticEvent(
                        .relayPolicyRefreshFailed,
                        b: Self.diagnosticFailureKind(for: error).rawValue
                    ))
                    let failureDate = Date()
                    if Self.shouldDeactivateRelayPolicy(
                        policyExpiresAt: snapshot.policyExpiresAt,
                        now: failureDate
                    ) {
                        let expired = await service.restore(
                            accountID: accountID,
                            trustRoot: trustRoot,
                            now: failureDate
                        )
                        try? await self.applyRelayPolicy(expired)
                        relayAuthorityExpired = true
                    } else {
                        self.relayPolicyDiagnostics = await service.diagnosticsSnapshot()
                        self.publishIrohSettingsUpdate()
                    }
                    let retryDelay = CmxIrohRetrySchedule().delay(
                        failureCount: failureCount,
                        retryAfterSeconds: (error as? CmxIrohTrustBrokerClientError)?
                            .retryAfterSeconds,
                        jitterUnitInterval: Double.random(in: 0 ... 1)
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

    nonisolated static func relayPolicyRefreshAttemptDate(
        policyExpiresAt: Date?,
        retryAt: Date?,
        now: Date
    ) -> Date {
        if let retryAt {
            return min(retryAt, policyExpiresAt ?? retryAt)
        }
        if let policyExpiresAt {
            return policyExpiresAt.addingTimeInterval(-60)
        }
        return now.addingTimeInterval(30)
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

    private func applyRelayPolicy(
        _ effective: CmxIrohEffectiveRelayPolicy
    ) async throws {
        relayPolicyEffective = effective
        relayPolicyDiagnostics = await relayPolicyService?.diagnosticsSnapshot()
        if let runtime {
            try await runtime.replaceRelayPolicy(effective)
        }
        publishIrohSettingsUpdate()
    }

    func clearRelayPolicyRuntimeState() {
        relayPolicyObservationTask?.cancel()
        relayPolicyObservationTask = nil
        relayPolicyRefreshTask?.cancel()
        relayPolicyRefreshTask = nil
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
