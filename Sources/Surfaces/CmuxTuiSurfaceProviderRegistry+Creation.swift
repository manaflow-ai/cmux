import Foundation

extension CmuxTuiSurfaceProviderRegistry {
    /// How long the CLI may answer `vm.cmux_remote_info` from a create receipt.
    nonisolated static let createAttachCacheLifetime: TimeInterval = 600

    /// Publishes the create response's friendly name before the first workspace bind.
    /// A response without private addresses leaves transport initialization and
    /// registration to discovery, as before.
    func recordCreatedMachine(_ summary: VMSummary, scope: UUID?) {
        guard let scope, scope == creationScope, let catalog else { return }
        // A replay cannot overwrite names or status already accepted by discovery.
        guard catalog.machines[.cloud(summary.id)] == nil else { return }
        pendingMachineCreationIDs.insert(summary.id)
        catalog.admitMachineCreationReceipt(CmuxTuiSurfaceProvider.info(
            from: summary, linkState: .connecting, linkError: nil, stats: nil
        ))
    }

    /// Admits a create response that already carries the machine's private address:
    /// stores the route, registers a provider exactly as discovery would, keeps the
    /// attach block for the CLI, and, for a trusted listener, saves the carrier
    /// marker so the first link dials with no control-plane call. Returns the
    /// registered provider, or nil when the response cannot be dialed yet (then the
    /// receipt is published the old way and discovery still owns registration).
    @discardableResult
    func recordCreatedMachine(_ summary: VMSummary, attach: VMCreateAttach?, scope: UUID?) async -> CmuxTuiSurfaceProvider? {
        guard let scope, scope == creationScope, let catalog else { return nil }
        if let attach { createAttachCache[summary.id] = attach }
        if let existing = providers[summary.id] { return existing }
        let addresses = [summary.addressIPv4, summary.addressIPv6].compactMap { $0 }
        guard !addresses.isEmpty else {
            recordCreatedMachine(summary, scope: scope)
            return nil
        }
        // Receipts are owned by this registry until a fleet page positively observes
        // them; a stale page fetched before the create must not prune the provider.
        pendingMachineCreationIDs.insert(summary.id)
        if catalog.machines[.cloud(summary.id)] == nil {
            catalog.admitMachineCreationReceipt(CmuxTuiSurfaceProvider.info(
                from: summary, linkState: .connecting, linkError: nil, stats: nil
            ))
        }
        let epoch = accessEpoch
        // A machine listed again after a delete waits for that delete's teardown,
        // so the teardown cannot close the new provider's forwards or link.
        if let teardown = machineTeardowns.removeValue(forKey: registeredMachineID(matching: summary.id)) {
            await teardown.value
        }
        await links.setPrivateAddresses(addresses, for: summary.id)
        if attach?.trustedCarrier == true {
            await links.recordTrustedCarrier(machineID: summary.id)
        }
        guard !isRetired, epoch == accessEpoch, scope == creationScope, !Task.isCancelled,
              let catalog = self.catalog else { return nil }
        if let existing = providers[summary.id] { return existing }
        let provider = CmuxTuiSurfaceProvider(
            summary: summary, links: links, catalog: catalog,
            portForwards: portForwards, portAccessStore: portAccess
        )
        providers[summary.id] = provider
        catalog.register(provider)
#if DEBUG
        cmuxDebugLog("cloud.create.registered machine=\(summary.id) addresses=\(addresses.count) trustedCarrier=\(attach?.trustedCarrier == true)")
#endif
        return provider
    }

    /// The attach block a create response supplied for this machine in this process,
    /// while it is fresh; nil once it expires, after deletion, or after sign-out.
    func cachedCreateAttach(machineID: String, now: Date = Date()) -> VMCreateAttach? {
        guard !isRetired, let attach = createAttachCache[machineID] else { return nil }
        guard now.timeIntervalSince(attach.receivedAt) < Self.createAttachCacheLifetime else {
            createAttachCache[machineID] = nil
            return nil
        }
        return attach
    }

    /// Dials a machine created moments ago from its create response, with the attach
    /// endpoint as the one-shot repair when the daemon did not answer in the budget.
    func connectFreshMachine(machineID: String, attach: VMCreateAttach) async throws {
        guard !isRetired, isCloudEnabled() else {
            throw CloudMachineLinkManager.ManagerError.retryLater(String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            ))
        }
        let links = self.links
        _ = try await links.connectFreshMachine(
            machineID: machineID,
            route: attach.route,
            session: attach.session,
            repair: {
                let client = await MainActor.run { VMClient.shared }
                guard let client else {
                    throw VMClientError.malformedResponse("Cloud VM client is not available (not signed in).")
                }
                let endpoint = try await client.openCmuxRemote(
                    id: machineID,
                    deviceFingerprint: nil,
                    clientCapabilities: await links.clientCapabilities()
                )
                guard endpoint.trustedCarrier else {
                    throw CloudMachineLinkManager.ManagerError.retryLater(String(
                        localized: "cloud.link.trustedListenerPending",
                        defaultValue: "The Cloud machine is still preparing remote access. Try again shortly."
                    ))
                }
                return endpoint.route
            }
        )
    }
}
