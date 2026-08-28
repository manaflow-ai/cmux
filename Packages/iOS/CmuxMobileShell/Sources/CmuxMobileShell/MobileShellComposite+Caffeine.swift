internal import CMUXMobileCore
public import CmuxMobileRPC
internal import Foundation
internal import OSLog

nonisolated private let caffeineLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-caffeine"
)

extension MobileShellComposite {
    private static let caffeineRequestTimeoutNanoseconds: UInt64 = 5_000_000_000

    // MARK: - Per-Mac surface

    /// Keep-awake is controlled per Mac: the foreground connection and each
    /// live control (secondary) connection carry their own state, so every
    /// read and mutation names the exact pairing it targets.
    public func caffeineStatus(
        macDeviceID: String,
        instanceTag: String?
    ) -> MobileCaffeineStatus? {
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if key == foregroundMacKey { return caffeineStatus }
        // A dict entry is only trusted while its control connection is live;
        // retirement paths don't have to chase entries down.
        guard secondaryMacSubscriptions[key] != nil else { return nil }
        return secondaryCaffeineStatusesByPairingID[key.pairingID]
    }

    /// Whether the phone can control keep-awake on this pairing right now:
    /// a live connection whose host advertises `caffeine.control.v1`.
    public func supportsCaffeineControl(
        macDeviceID: String,
        instanceTag: String?
    ) -> Bool {
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if key == foregroundMacKey { return supportsCaffeineControl }
        return secondaryMacSubscriptions[key]?
            .supportedHostCapabilities
            .contains(Self.caffeineControlCapability) == true
    }

    /// Whether a keep-awake mutation is awaiting this pairing's Mac.
    public func isCaffeineMutationInFlight(
        macDeviceID: String,
        instanceTag: String?
    ) -> Bool {
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if key == foregroundMacKey { return isCaffeineMutationInFlight }
        return secondaryCaffeineMutationPairingIDs.contains(key.pairingID)
    }

    /// Pairing ids with any keep-awake mutation in flight, for row-level busy
    /// states on the Computers screen.
    public var caffeineMutatingPairingIDs: Set<String> {
        var ids = secondaryCaffeineMutationPairingIDs
        if isCaffeineMutationInFlight {
            ids.insert(foregroundMacKey.pairingID)
        }
        return ids
    }

    /// Reads the named Mac's authoritative keep-awake state.
    @discardableResult
    public func refreshCaffeineStatus(
        macDeviceID: String,
        instanceTag: String?
    ) async -> Bool {
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if key == foregroundMacKey {
            return await refreshForegroundCaffeineStatus()
        }
        return await refreshSecondaryCaffeineStatus(ownerKey: key)
    }

    /// Changes keep-awake on the named Mac.
    @discardableResult
    public func setCaffeineEnabled(
        _ enabled: Bool,
        macDeviceID: String,
        instanceTag: String?
    ) async -> Bool {
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if key == foregroundMacKey {
            return await setForegroundCaffeineEnabled(enabled)
        }
        return await setSecondaryCaffeineEnabled(enabled, ownerKey: key)
    }

    // MARK: - Seeding

    /// The Computers rows show a keep-awake indicator without any detail view
    /// open, so the foreground state is read as soon as the host's capability
    /// snapshot proves the RPC exists.
    func seedForegroundCaffeineStatusIfSupported() {
        guard supportsCaffeineControl, caffeineStatus == nil,
              !isCaffeineMutationInFlight else { return }
        Task { @MainActor [weak self] in
            _ = await self?.refreshForegroundCaffeineStatus()
        }
    }

    /// Seeds one freshly established control connection's keep-awake state.
    func seedSecondaryCaffeineStatus(_ subscription: SecondaryMacSubscription) {
        guard subscription.supportedHostCapabilities.contains(
            Self.caffeineControlCapability
        ) else { return }
        let ownerKey = subscription.ownerKey
        guard secondaryCaffeineStatusesByPairingID[ownerKey.pairingID] == nil else {
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.refreshSecondaryCaffeineStatus(ownerKey: ownerKey)
        }
    }

    /// Promotion publishes the control connection's capability snapshot
    /// directly (no host-status round trip), so the control entry's known
    /// state moves into the foreground slot instead of waiting for a refresh.
    func adoptSecondaryCaffeineStatusForPromotedForeground(ownerKey: MacPairingKey) {
        guard caffeineStatus == nil, !isCaffeineMutationInFlight,
              let adopted = secondaryCaffeineStatusesByPairingID[ownerKey.pairingID]
        else { return }
        secondaryCaffeineStatusesByPairingID[ownerKey.pairingID] = nil
        caffeineStatus = adopted
        caffeineStatusRevision &+= 1
    }

    /// Fills keep-awake state that a promotion, demotion, or failed seed left
    /// missing on a live connection. Called from the Computers screen's gentle
    /// refresh cadence; only connections without state are asked.
    func backfillMissingCaffeineStatuses() {
        seedForegroundCaffeineStatusIfSupported()
        for (ownerKey, subscription) in secondaryMacSubscriptions {
            guard subscription.supportedHostCapabilities.contains(
                Self.caffeineControlCapability
            ), secondaryCaffeineStatusesByPairingID[ownerKey.pairingID] == nil,
                !secondaryCaffeineMutationPairingIDs.contains(ownerKey.pairingID)
            else { continue }
            Task { @MainActor [weak self] in
                _ = await self?.refreshSecondaryCaffeineStatus(ownerKey: ownerKey)
            }
        }
    }

    // MARK: - Foreground connection

    /// Reads the current Mac's authoritative cmux-owned keep-awake state.
    @discardableResult
    func refreshForegroundCaffeineStatus(
        preservingRevision expectedRevision: UInt64? = nil
    ) async -> Bool {
        guard supportsCaffeineControl, let client = remoteClient else {
            caffeineStatus = nil
            return false
        }
        let generation = connectionGeneration
        let requestRevision = expectedRevision ?? caffeineStatusRevision
        guard expectedRevision == nil || caffeineStatusRevision == expectedRevision else {
            return false
        }
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "caffeine.status",
                    params: [:]
                ),
                timeoutNanoseconds: Self.caffeineRequestTimeoutNanoseconds
            )
            let status = try MobileCaffeineStatus(decoding: data)
            guard isCurrentRemoteOperation(
                client: client,
                generation: generation
            ) else { return false }
            guard caffeineStatusRevision == requestRevision else {
                return caffeineStatus != nil
            }
            caffeineStatus = status
            caffeineStatusRevision &+= 1
            return true
        } catch {
            guard remoteClient === client,
                  connectionGeneration == generation,
                  caffeineStatusRevision == requestRevision else { return false }
            caffeineStatus = nil
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                return false
            }
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            caffeineLog.error(
                "caffeine.status failed error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Optimistically changes keep-awake, then replaces the optimistic value
    /// with the Mac's response or rolls it back on a current-connection error.
    @discardableResult
    func setForegroundCaffeineEnabled(_ enabled: Bool) async -> Bool {
        guard supportsCaffeineControl,
              !isCaffeineMutationInFlight,
              let client = remoteClient else { return false }

        let generation = connectionGeneration
        let mutationID = UUID()
        caffeineMutationID = mutationID
        isCaffeineMutationInFlight = true
        caffeineStatusRevision &+= 1
        let requestRevision = caffeineStatusRevision
        caffeineStatus = MobileCaffeineStatus(enabled: enabled)
        defer {
            if caffeineMutationID == mutationID {
                caffeineMutationID = nil
                isCaffeineMutationInFlight = false
            }
        }

        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "caffeine.set",
                    params: ["enabled": enabled]
                ),
                timeoutNanoseconds: Self.caffeineRequestTimeoutNanoseconds
            )
            let status = try MobileCaffeineStatus(decoding: data)
            guard isCurrentRemoteOperation(
                client: client,
                generation: generation
            ), caffeineMutationID == mutationID else { return false }
            guard caffeineStatusRevision == requestRevision else {
                return caffeineStatus?.enabled == enabled
            }
            caffeineStatus = status
            caffeineStatusRevision &+= 1
            return true
        } catch {
            guard remoteClient === client,
                  connectionGeneration == generation,
                  caffeineMutationID == mutationID else { return false }
            guard caffeineStatusRevision == requestRevision else {
                return caffeineStatus?.enabled == enabled
            }
            let statusRevision = caffeineStatusRevision
            // A timed-out or malformed response is ambiguous: caffeine.set may
            // have reached the Mac before the response was lost. Keep the UI in
            // an unknown state until a bounded status read confirms the result.
            caffeineStatus = nil
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                return false
            }
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            caffeineLog.error(
                "caffeine.set failed error=\(String(describing: error), privacy: .public)"
            )
            _ = await refreshForegroundCaffeineStatus(
                preservingRevision: statusRevision
            )
            return caffeineStatus?.enabled == enabled
        }
    }

    func handleCaffeineStatusEvent(
        _ event: MobileEventEnvelope,
        client: MobileCoreRPCClient,
        generation: UUID
    ) {
        guard isCurrentRemoteOperation(client: client, generation: generation) else {
            return
        }
        guard let payload = event.payloadJSON,
              let status = try? MobileCaffeineStatus(decoding: payload) else {
            return
        }
        caffeineStatus = status
        caffeineStatusRevision &+= 1
    }

    // MARK: - Control (secondary) connections

    func handleSecondaryCaffeineStatusEvent(
        _ event: MobileEventEnvelope,
        ownerKey: MacPairingKey
    ) {
        guard let payload = event.payloadJSON,
              let status = try? MobileCaffeineStatus(decoding: payload) else {
            return
        }
        secondaryCaffeineStatusesByPairingID[ownerKey.pairingID] = status
    }

    private func refreshSecondaryCaffeineStatus(ownerKey: MacPairingKey) async -> Bool {
        guard let subscription = secondaryMacSubscriptions[ownerKey],
              subscription.supportedHostCapabilities.contains(
                Self.caffeineControlCapability
              ) else {
            secondaryCaffeineStatusesByPairingID[ownerKey.pairingID] = nil
            return false
        }
        let client = subscription.client
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "caffeine.status",
                    params: [:]
                ),
                timeoutNanoseconds: Self.caffeineRequestTimeoutNanoseconds
            )
            let status = try MobileCaffeineStatus(decoding: data)
            guard isCurrentSecondaryCaffeineOperation(
                ownerKey: ownerKey,
                client: client
            ) else { return false }
            // An in-flight mutation owns the optimistic value; its own
            // reconciliation lands the authoritative state.
            guard !secondaryCaffeineMutationPairingIDs.contains(ownerKey.pairingID)
            else { return true }
            secondaryCaffeineStatusesByPairingID[ownerKey.pairingID] = status
            return true
        } catch {
            guard isCurrentSecondaryCaffeineOperation(
                ownerKey: ownerKey,
                client: client
            ) else { return false }
            if !secondaryCaffeineMutationPairingIDs.contains(ownerKey.pairingID) {
                secondaryCaffeineStatusesByPairingID[ownerKey.pairingID] = nil
            }
            caffeineLog.error(
                "caffeine.status (control) failed mac=\(ownerKey.pairingID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    private func setSecondaryCaffeineEnabled(
        _ enabled: Bool,
        ownerKey: MacPairingKey
    ) async -> Bool {
        let pairingID = ownerKey.pairingID
        guard !secondaryCaffeineMutationPairingIDs.contains(pairingID),
              let subscription = secondaryMacSubscriptions[ownerKey],
              subscription.supportedHostCapabilities.contains(
                Self.caffeineControlCapability
              ) else { return false }
        let client = subscription.client
        secondaryCaffeineMutationPairingIDs.insert(pairingID)
        secondaryCaffeineStatusesByPairingID[pairingID] =
            MobileCaffeineStatus(enabled: enabled)
        defer { secondaryCaffeineMutationPairingIDs.remove(pairingID) }
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "caffeine.set",
                    params: ["enabled": enabled]
                ),
                timeoutNanoseconds: Self.caffeineRequestTimeoutNanoseconds
            )
            let status = try MobileCaffeineStatus(decoding: data)
            guard isCurrentSecondaryCaffeineOperation(
                ownerKey: ownerKey,
                client: client
            ) else { return false }
            secondaryCaffeineStatusesByPairingID[pairingID] = status
            return true
        } catch {
            guard isCurrentSecondaryCaffeineOperation(
                ownerKey: ownerKey,
                client: client
            ) else { return false }
            // Same ambiguity as the foreground path: the set may have landed
            // before the response was lost, so the state is unknown until a
            // bounded status read confirms it.
            secondaryCaffeineStatusesByPairingID[pairingID] = nil
            caffeineLog.error(
                "caffeine.set (control) failed mac=\(pairingID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            secondaryCaffeineMutationPairingIDs.remove(pairingID)
            _ = await refreshSecondaryCaffeineStatus(ownerKey: ownerKey)
            return secondaryCaffeineStatusesByPairingID[pairingID]?.enabled == enabled
        }
    }

    /// Whether the subscription this request was sent on still owns its pool
    /// slot; a retired or replaced control connection's stale response must
    /// not overwrite the replacement's state.
    private func isCurrentSecondaryCaffeineOperation(
        ownerKey: MacPairingKey,
        client: MobileCoreRPCClient
    ) -> Bool {
        guard let current = secondaryMacSubscriptions[ownerKey] else { return false }
        return current.client === client
    }
}
