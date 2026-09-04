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
        guard try await applyRelayPolicy(
            effective,
            expectedServicePolicy: effective
        ) else {
            throw SettingsError.superseded
        }
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
        guard try await applyRelayPolicy(
            effective,
            expectedServicePolicy: effective
        ) else {
            throw SettingsError.superseded
        }
        if definition.authMode == .staticToken, let deviceSecret {
            effective = try await context.service.setStaticCredential(
                deviceSecret,
                relayID: definition.id,
                relayURL: definition.url,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: Date()
            )
            guard try await applyRelayPolicy(
                effective,
                expectedServicePolicy: effective
            ) else {
                throw SettingsError.superseded
            }
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
        guard try await applyRelayPolicy(
            effective,
            expectedServicePolicy: effective
        ) else {
            throw SettingsError.superseded
        }
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
        // Connection diagnostics must describe the policy the live endpoint
        // accepted, not a newer service-side resolution.
        if transportVerificationMode == .directOnly {
            // Relays are administratively excluded by the transport mode; a
            // failed relay probe here must not send users to corporate IT.
            relayReachability = .notConfigured
        } else if let profile = relayPolicyAppliedEffective?.endpointRelayProfile,
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
        let refreshRevision = lifecycleRevision
        diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshStarted))
        do {
            let effective = try await context.service.refresh(
                endpointID: context.endpointID,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: Date()
            )
            guard refreshRevision == lifecycleRevision,
                  relayPolicyService === context.service,
                  activeAccountID == context.accountID,
                  relayPolicyEndpointID == context.endpointID else {
                return
            }
            guard try await applyRelayPolicy(
                effective,
                expectedServicePolicy: effective
            ) else { return }
            diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
        } catch {
            guard refreshRevision == lifecycleRevision,
                  relayPolicyService === context.service,
                  activeAccountID == context.accountID,
                  relayPolicyEndpointID == context.endpointID else {
                return
            }
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
                    relayPolicy: self.relayPolicyAppliedEffective
                        ?? self.relayPolicyEffective
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
        cancelRelayPolicyRefresh()
        guard let service, let trustRoot else {
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
            var deactivationRetryAt: Date?
            var deactivationRetryAppliedPolicy: CmxIrohEffectiveRelayPolicy?
            var deactivationFailureCount = 0
            var shouldRefreshImmediately = refreshImmediately
            while !Task.isCancelled {
                guard let self,
                      self.ownsRelayPolicyRefresh(
                          taskID: taskID,
                          service: service,
                          accountID: accountID,
                          revision: revision
                      ) else { return }
                let snapshot = await service.diagnosticsSnapshot()
                let clock = self.relayPolicyRefreshClock
                let current = clock.now()
                if let retryPolicy = deactivationRetryAppliedPolicy,
                   self.relayPolicyAppliedEffective != retryPolicy {
                    // A failed application can be superseded by a settings
                    // mutation while its retry deadline is pending. Do not
                    // let that old deadline drive expiry work for a different
                    // endpoint policy generation.
                    deactivationRetryAt = nil
                    deactivationRetryAppliedPolicy = nil
                    deactivationFailureCount = 0
                }
                let refreshPolicyExpiresAt = snapshot.policyExpiresAt
                let deactivationPolicyExpiresAt = self.usesManagedRelayAuthority
                    ? Self.earliestRelayPolicyExpiry(
                        servicePolicyExpiresAt: refreshPolicyExpiresAt,
                        appliedPolicyExpiresAt: self.appliedRelayPolicyExpiresAt
                    )
                    : nil
                let attemptAt: Date
                if self.relayPolicyNetworkReachable != true {
                    // Keep a local expiry deadline alive while broker work is
                    // parked. There is no network request on this path; it
                    // only wakes to remove expired relay authority.
                    guard let policyExpiresAt = Self.relayPolicyOfflineExpiryAttemptDate(
                        policyExpiresAt: deactivationPolicyExpiresAt,
                        retryAt: deactivationRetryAt,
                        now: current
                    ) else {
                        return
                    }
                    attemptAt = policyExpiresAt
                } else if shouldRefreshImmediately {
                    attemptAt = current
                    shouldRefreshImmediately = false
                } else {
                    let nextRetryAt = [retryAt, deactivationRetryAt]
                        .compactMap { $0 }
                        .min()
                    let refreshAttemptAt = Self.relayPolicyRefreshAttemptDate(
                        policyExpiresAt: relayAuthorityExpired
                            ? nil
                            : refreshPolicyExpiresAt,
                        retryAt: nextRetryAt,
                        now: current
                    )
                    // Keep the endpoint's applied authority on its own wake
                    // path. A newer service catalog may expire later while an
                    // older managed profile is still installed and must be
                    // revoked at its earlier expiry.
                    let deactivationAttemptAt = relayAuthorityExpired
                        ? nil
                        : (deactivationRetryAt ?? deactivationPolicyExpiresAt)
                    attemptAt = [refreshAttemptAt, deactivationAttemptAt]
                        .compactMap { $0 }
                        .min() ?? refreshAttemptAt
                }
                let delay = attemptAt.timeIntervalSince(current)
                if delay > 0 {
                    do {
                        // This is the bounded retry deadline itself, not a
                        // polling/settling sleep. A reachable-path transition
                        // cancels it and owns the immediate recovery wake;
                        // an offline transition keeps the local expiry wake.
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
                      ) else { return }
                let wakeSnapshot = await service.diagnosticsSnapshot()
                guard !Task.isCancelled,
                      self.ownsRelayPolicyRefresh(
                          taskID: taskID,
                          service: service,
                          accountID: accountID,
                          revision: revision
                      ) else { return }
                let wakeDeactivationPolicyExpiresAt = self.usesManagedRelayAuthority
                    ? Self.earliestRelayPolicyExpiry(
                        servicePolicyExpiresAt: wakeSnapshot.policyExpiresAt,
                        appliedPolicyExpiresAt: self.appliedRelayPolicyExpiresAt
                    )
                    : nil
                if let retryPolicy = deactivationRetryAppliedPolicy,
                   self.relayPolicyAppliedEffective != retryPolicy {
                    // A failed application can be superseded by a settings
                    // mutation while its retry deadline is pending. Do not
                    // let that old deadline drive expiry work for a different
                    // endpoint policy generation.
                    deactivationRetryAt = nil
                    deactivationRetryAppliedPolicy = nil
                    deactivationFailureCount = 0
                }
                let shouldAttemptDeactivation = !relayAuthorityExpired
                    && Self.shouldDeactivateRelayPolicy(
                        policyExpiresAt: wakeDeactivationPolicyExpiresAt,
                        now: wakeDate
                    )
                if shouldAttemptDeactivation {
                    let expectedReachability = self.relayPolicyNetworkReachable == true
                    do {
                        let didApply = try await self.expireAndApplyRelayPolicy(
                            service: service,
                            accountID: accountID,
                            taskID: taskID,
                            expectedReachability: expectedReachability
                        )
                        guard didApply else {
                            guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                            self.armRelayPolicyDeactivationRetry(
                                now: clock.now(),
                                appliedPolicy: self.relayPolicyAppliedEffective,
                                retryPolicy: &deactivationRetryAppliedPolicy,
                                failureCount: &deactivationFailureCount,
                                retryAt: &deactivationRetryAt
                            )
                            continue
                        }
                        guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                        relayAuthorityExpired = true
                        deactivationRetryAt = nil
                        deactivationRetryAppliedPolicy = nil
                        deactivationFailureCount = 0
                    } catch {
                        // Keep the endpoint fail-closed goal alive when a local
                        // replacement is transiently rejected. The retry is a
                        // bounded deadline, not a network poll.
                        guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                        self.armRelayPolicyDeactivationRetry(
                            now: clock.now(),
                            appliedPolicy: self.relayPolicyAppliedEffective,
                            retryPolicy: &deactivationRetryAppliedPolicy,
                            failureCount: &deactivationFailureCount,
                            retryAt: &deactivationRetryAt
                        )
                        continue
                    }
                    guard self.relayPolicyNetworkReachable == true else { return }
                    continue
                }
                if self.relayPolicyNetworkReachable != true {
                    // A pre-existing retry deadline may wake before policy
                    // expiry. Re-enter the parked branch so it retains the
                    // later local deactivation deadline instead of dropping
                    // the task.
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
                          ) else { return }
                    guard self.relayPolicyNetworkReachable == true else {
                        // The broker result may have completed as the path
                        // dropped. Leave endpoint state untouched and let the
                        // offline expiry branch own the next local action.
                        continue
                    }
                    guard await service.effectivePolicy() == effective else {
                        guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                        retryAt = clock.now().addingTimeInterval(
                            CmxIrohRetrySchedule.macHostRelayPolicy.initialDelay
                        )
                        continue
                    }
                    let expectedAppliedPolicy = self.relayPolicyAppliedEffective
                    let didApply = try await self.applyRelayPolicy(
                        effective,
                        refreshTaskID: taskID,
                        expectedServicePolicy: effective,
                        expectedAppliedPolicy: expectedAppliedPolicy,
                        requireAppliedPolicyMatch: true
                    )
                    guard didApply else {
                        // A path transition can invalidate an otherwise valid
                        // broker result while the local replacement suspends.
                        // Re-enter the loop so the offline expiry deadline is
                        // still honored instead of dropping the task. Keep a
                        // bounded retry deadline so an invalidated result
                        // cannot spin the main actor.
                        guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                        retryAt = clock.now().addingTimeInterval(
                            CmxIrohRetrySchedule.macHostRelayPolicy.initialDelay
                        )
                        continue
                    }
                    guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                    retryAt = nil
                    failureCount = 0
                    relayAuthorityExpired = false
                    deactivationRetryAt = nil
                    deactivationRetryAppliedPolicy = nil
                    deactivationFailureCount = 0
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
                    ) else { continue }
                    let failureDate = clock.now()
                    if Self.shouldDeactivateRelayPolicy(
                        policyExpiresAt: Self.earliestRelayPolicyExpiry(
                            servicePolicyExpiresAt: self.usesManagedRelayAuthority
                                ? snapshot.policyExpiresAt
                                : nil,
                            appliedPolicyExpiresAt: self.appliedRelayPolicyExpiresAt
                        ),
                        now: failureDate
                    ) {
                        let expectedReachability = self.relayPolicyNetworkReachable == true
                        do {
                            let didApply = try await self.expireAndApplyRelayPolicy(
                                service: service,
                                accountID: accountID,
                                taskID: taskID,
                                expectedReachability: expectedReachability
                            )
                            guard didApply else {
                                guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                                self.armRelayPolicyDeactivationRetry(
                                    now: clock.now(),
                                    appliedPolicy: self.relayPolicyAppliedEffective,
                                    retryPolicy: &deactivationRetryAppliedPolicy,
                                    failureCount: &deactivationFailureCount,
                                    retryAt: &deactivationRetryAt
                                )
                                continue
                            }
                            guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                            relayAuthorityExpired = true
                            deactivationRetryAt = nil
                            deactivationRetryAppliedPolicy = nil
                            deactivationFailureCount = 0
                        } catch {
                            // A failed live replacement must not be marked as
                            // expired authority; retain a bounded local retry
                            // so an offline/expired endpoint cannot keep its
                            // old relay profile indefinitely.
                            guard self.ownsRelayPolicyRefreshTask(taskID) else { return }
                            self.armRelayPolicyDeactivationRetry(
                                now: failureDate,
                                appliedPolicy: self.relayPolicyAppliedEffective,
                                retryPolicy: &deactivationRetryAppliedPolicy,
                                failureCount: &deactivationFailureCount,
                                retryAt: &deactivationRetryAt
                            )
                            continue
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

    /// Arms the bounded local retry used when expiry application is
    /// invalidated by a concurrent path or policy generation change.
    private func armRelayPolicyDeactivationRetry(
        now: Date,
        appliedPolicy: CmxIrohEffectiveRelayPolicy?,
        retryPolicy: inout CmxIrohEffectiveRelayPolicy?,
        failureCount: inout Int,
        retryAt: inout Date?
    ) {
        guard let appliedPolicy, appliedPolicy.source == .managed else {
            retryPolicy = nil
            failureCount = 0
            retryAt = nil
            return
        }
        retryPolicy = appliedPolicy
        let retryDelay = CmxIrohRetrySchedule.macHostRelayPolicy.delay(
            failureCount: failureCount,
            retryAfterSeconds: nil,
            jitterUnitInterval: relayPolicyRetryJitter()
        )
        failureCount = min(failureCount + 1, 20)
        retryAt = now.addingTimeInterval(retryDelay)
        diagnosticLog.record(DiagnosticEvent(
            .retryScheduled,
            ms: UInt32(clamping: Int(retryDelay * 1_000)),
            a: DiagnosticTransportKind.iroh.rawValue
        ))
    }

    /// Produces and installs the empty managed profile used at endpoint-policy
    /// expiry, retaining the reachability class that was observed before the
    /// suspending service operation.
    private func expireAndApplyRelayPolicy(
        service: CmxIrohRelayPolicyService,
        accountID: String,
        taskID: UUID,
        expectedReachability: Bool
    ) async throws -> Bool {
        // Do not restore from the service cache here. A refresh may have
        // committed a newer catalog while its endpoint installation was
        // suspended; this operation intentionally creates an empty managed
        // profile for the authority that is actually installed.
        guard let appliedPolicy = relayPolicyAppliedEffective,
              appliedPolicy.source == .managed,
              let expired = service.expireManagedPolicy(
                  appliedPolicy: appliedPolicy
              ) else {
            return false
        }
        guard !Task.isCancelled,
              ownsRelayPolicyRefreshTask(taskID),
              relayPolicyAppliedEffective == appliedPolicy,
              (relayPolicyNetworkReachable == true) == expectedReachability else {
            return false
        }
        return try await applyRelayPolicy(
            expired,
            refreshTaskID: taskID,
            allowOffline: true,
            expectedReachability: expectedReachability,
            expectedAppliedPolicy: appliedPolicy,
            requireAppliedPolicyMatch: true,
            appliedFailure: .policyExpired,
            updatesResolvedState: false
        )
    }

    /// Expiry of the policy installed on the endpoint, rather than a newer
    /// policy that the service may have resolved but not yet applied.
    private var appliedRelayPolicyExpiresAt: Date? {
        guard let effective = relayPolicyAppliedEffective,
              effective.source == .managed,
              let policy = effective.managedPolicy else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(policy.expiresAt))
    }

    /// Whether the live endpoint currently uses a broker-managed profile.
    /// Custom relay profiles may retain a managed catalog for display, but its
    /// catalog expiry is not an authority expiry for the custom endpoint.
    private var usesManagedRelayAuthority: Bool {
        relayPolicyAppliedEffective?.source == .managed
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

    /// Returns the local deadline that remains actionable while broker refresh
    /// is parked by an unavailable path. A missing expiry means there is no
    /// local authority to revoke, so the caller can end the parked task and
    /// let the next reachable-path callback recreate it.
    nonisolated static func relayPolicyOfflineExpiryAttemptDate(
        policyExpiresAt: Date?,
        retryAt: Date? = nil,
        now: Date
    ) -> Date? {
        guard let policyExpiresAt else { return nil }
        guard retryAt != nil else { return max(now, policyExpiresAt) }
        return relayPolicyRefreshAttemptDate(
            policyExpiresAt: policyExpiresAt,
            retryAt: retryAt,
            now: now
        )
    }

    /// Chooses the earliest known policy expiry so a newer uninstalled cache
    /// value can never postpone revocation of the live endpoint authority.
    nonisolated static func earliestRelayPolicyExpiry(
        servicePolicyExpiresAt: Date?,
        appliedPolicyExpiresAt: Date?
    ) -> Date? {
        [servicePolicyExpiresAt, appliedPolicyExpiresAt].compactMap { $0 }.min()
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
            guard await context.service.effectivePolicy() == effective else { return }
            guard try await applyRelayPolicy(
                effective,
                expectedServicePolicy: effective
            ) else { return }
        } catch {
            guard relayPolicyService === context.service,
                  activeAccountID == context.accountID else { return }
            relayPolicyDiagnostics = await context.service.diagnosticsSnapshot()
            publishIrohSettingsUpdate()
        }
    }

    /// Installs a policy, optionally fenced to one refresh-task generation.
    @discardableResult
    private func applyRelayPolicy(
        _ effective: CmxIrohEffectiveRelayPolicy,
        refreshTaskID: UUID? = nil,
        allowOffline: Bool = false,
        expectedReachability: Bool? = nil,
        expectedServicePolicy: CmxIrohEffectiveRelayPolicy? = nil,
        expectedAppliedPolicy: CmxIrohEffectiveRelayPolicy? = nil,
        requireAppliedPolicyMatch: Bool = false,
        appliedFailure: CmxIrohRelayPolicyFailure? = nil,
        updatesResolvedState: Bool = true
    ) async throws -> Bool {
        relayPolicyApplicationGeneration &+= 1
        let applicationGeneration = relayPolicyApplicationGeneration
        let requestID = UUID()
        let previous = relayPolicyApplicationTail
        let expectedRuntime = runtime
        let task = Task { @MainActor [weak self] () throws -> Bool in
            if let previous {
                _ = try? await previous.value
            }
            guard let self,
                  self.relayPolicyApplicationGeneration == applicationGeneration,
                  self.relayPolicyApplicationTaskID == requestID,
                  self.ownsRelayPolicyRuntime(expectedRuntime) else {
                return false
            }
            return try await self.performRelayPolicyApplication(
                effective,
                expectedRuntime: expectedRuntime,
                refreshTaskID: refreshTaskID,
                allowOffline: allowOffline,
                expectedReachability: expectedReachability,
                expectedServicePolicy: expectedServicePolicy,
                expectedAppliedPolicy: expectedAppliedPolicy,
                requireAppliedPolicyMatch: requireAppliedPolicyMatch,
                appliedFailure: appliedFailure,
                updatesResolvedState: updatesResolvedState,
                applicationGeneration: applicationGeneration
            )
        }
        relayPolicyApplicationTail = task
        relayPolicyApplicationTaskID = requestID
        defer {
            if relayPolicyApplicationTaskID == requestID {
                relayPolicyApplicationTail = nil
                relayPolicyApplicationTaskID = nil
            }
        }
        return try await task.value
    }

    private func performRelayPolicyApplication(
        _ effective: CmxIrohEffectiveRelayPolicy,
        expectedRuntime: CmxIrohHostRuntime?,
        refreshTaskID: UUID?,
        allowOffline: Bool,
        expectedReachability: Bool?,
        expectedServicePolicy: CmxIrohEffectiveRelayPolicy?,
        expectedAppliedPolicy: CmxIrohEffectiveRelayPolicy?,
        requireAppliedPolicyMatch: Bool,
        appliedFailure: CmxIrohRelayPolicyFailure?,
        updatesResolvedState: Bool,
        applicationGeneration: UInt64
    ) async throws -> Bool {
        guard relayPolicyApplicationGeneration == applicationGeneration,
              ownsRelayPolicyRuntime(expectedRuntime) else {
            return false
        }
        let diagnostics = await relayPolicyService?.diagnosticsSnapshot()
        guard relayPolicyApplicationGeneration == applicationGeneration,
              ownsRelayPolicyRuntime(expectedRuntime) else {
            return false
        }
        if let refreshTaskID {
            guard ownsRelayPolicyRefreshTask(refreshTaskID),
                  canApplyRelayPolicy(
                      allowOffline: allowOffline,
                      expectedReachability: expectedReachability
                  ) else {
                return false
            }
        }
        if let expectedServicePolicy {
            guard let service = relayPolicyService,
                  await service.effectivePolicy() == expectedServicePolicy else {
                return false
            }
        }
        if requireAppliedPolicyMatch {
            guard relayPolicyAppliedEffective == expectedAppliedPolicy else {
                return false
            }
        }
        if let expectedRuntime {
            guard relayPolicyApplicationGeneration == applicationGeneration,
                  ownsRelayPolicyRuntime(expectedRuntime) else {
                return false
            }
            if let refreshTaskID {
                guard ownsRelayPolicyRefreshTask(refreshTaskID),
                      canApplyRelayPolicy(
                          allowOffline: allowOffline,
                          expectedReachability: expectedReachability
                      ) else {
                    return false
                }
            }
            try await expectedRuntime.replaceRelayPolicy(effective)
            // The endpoint replacement suspends. A lifecycle transition or a
            // newer request may have taken ownership while it was in flight;
            // never commit the stale result into that newer state.
            guard relayPolicyApplicationGeneration == applicationGeneration,
                  ownsRelayPolicyRuntime(expectedRuntime) else {
                return false
            }
        }
        // The endpoint mutation is authoritative for expiry bookkeeping. Do
        // not wait for the service-side fence before recording what it
        // accepted; a concurrent preference refresh may legitimately publish a
        // different resolved snapshot while this replacement suspends.
        if !requireAppliedPolicyMatch || relayPolicyAppliedEffective == expectedAppliedPolicy {
            relayPolicyAppliedEffective = effective
            relayPolicyAppliedFailure = appliedFailure
        }
        guard relayPolicyApplicationGeneration == applicationGeneration else {
            return false
        }
        if requireAppliedPolicyMatch {
            guard relayPolicyAppliedEffective == effective else {
                return false
            }
        }
        if let expectedServicePolicy {
            guard let service = relayPolicyService,
                  await service.effectivePolicy() == expectedServicePolicy else {
                return false
            }
        }
        if let refreshTaskID {
            guard ownsRelayPolicyRefreshTask(refreshTaskID),
                  canApplyRelayPolicy(
                      allowOffline: allowOffline,
                      expectedReachability: expectedReachability
                  ) else {
                return false
            }
        }
        if updatesResolvedState {
            relayPolicyEffective = effective
            relayPolicyDiagnostics = diagnostics
        }
        publishIrohSettingsUpdate()
        return true
    }

    /// Validates the path state for a refresh-task policy application. Local
    /// expiry revocation may proceed while offline, but only if the reachability
    /// class observed before the operation is still current after it suspends.
    private func canApplyRelayPolicy(
        allowOffline: Bool,
        expectedReachability: Bool?
    ) -> Bool {
        if let expectedReachability {
            guard (relayPolicyNetworkReachable == true) == expectedReachability else {
                return false
            }
            return expectedReachability || allowOffline
        }
        return allowOffline || relayPolicyNetworkReachable == true
    }

    /// Cancels the long-lived relay refresh task and clears its captured
    /// account context at every lifecycle boundary.
    func cancelRelayPolicyRefresh() {
        relayPolicyRefreshTask?.cancel()
        relayPolicyRefreshTask = nil
        relayPolicyRefreshTaskID = nil
        relayPolicyRefreshService = nil
        relayPolicyRefreshAccountID = nil
        relayPolicyRefreshEndpointID = nil
        relayPolicyRefreshTrustRoot = nil
        relayPolicyRefreshRevision = nil
    }

    /// Re-arms a refresh whose lifecycle owner was retained while an active
    /// same-account reconcile completed without replacing the endpoint.
    func rearmRelayPolicyRefreshIfNeeded() {
        guard relayPolicyRefreshTask == nil,
              let service = relayPolicyRefreshService,
              let accountID = relayPolicyRefreshAccountID,
              let endpointID = relayPolicyRefreshEndpointID,
              let trustRoot = relayPolicyRefreshTrustRoot,
              let revision = relayPolicyRefreshRevision,
              revision == lifecycleRevision,
              activeAccountID == accountID else { return }
        scheduleRelayPolicyRefresh(
            service: service,
            accountID: accountID,
            endpointID: endpointID,
            trustRoot: trustRoot,
            revision: revision,
            refreshImmediately: false
        )
    }

    /// Returns whether the endpoint captured by a policy application is still
    /// the runtime owned by this lifecycle generation. A captured nil asserts
    /// that no endpoint existed when the request began.
    private func ownsRelayPolicyRuntime(
        _ expectedRuntime: CmxIrohHostRuntime?
    ) -> Bool {
        guard let expectedRuntime else { return runtime == nil }
        guard let runtime else { return false }
        return runtime === expectedRuntime
    }

    /// Invalidates endpoint policy replacements before a lifecycle transition
    /// can suspend while stopping or activating a runtime.
    func invalidateRelayPolicyApplications() {
        relayPolicyApplicationGeneration &+= 1
        relayPolicyApplicationTail?.cancel()
        relayPolicyApplicationTail = nil
        relayPolicyApplicationTaskID = nil
    }

    /// Cancels relay-policy observers and clears the account-scoped refresh
    /// context without discarding the platform's last reachability sample.
    func clearRelayPolicyRuntimeState() {
        relayPolicyObservationTask?.cancel()
        relayPolicyObservationTask = nil
        cancelRelayPolicyRefresh()
        invalidateRelayPolicyApplications()
        serverSignalRefreshTask?.cancel()
        serverSignalRefreshTask = nil
        serverSignalRefreshTaskID = nil
        serverSignalRefreshRevision = nil
        serverSignalPendingRevision = nil
        serverSignalAccountID = nil
        relayPolicyService = nil
        relayPolicyAppliedEffective = nil
        relayPolicyAppliedFailure = nil
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
