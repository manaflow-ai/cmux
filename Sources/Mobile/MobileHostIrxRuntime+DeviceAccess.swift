import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

extension MobileHostIrxRuntime {
    /// Changes hosting without retiring the endpoint used by outgoing sessions.
    /// Every admission independently checks this preference, including during a publish.
    func reconcileIncomingAccess() async {
        let enabled = MobileRemoteControlPolicy.allowsIncomingAccess()
        if !enabled {
            await registry?.closeAll(code: .hostShutdown)
            await lanPublisher.stop()
            if publishesPublicHostStatus { MobileHostPublicStatusCache.update(irohIdentity: nil) }
        }
        guard registeredIncomingAccess != enabled,
              let broker = brokerService,
              let supervisor = endpointSupervisor,
              let binding = localBinding else { return }
        let generation = generationToken
        let relay = await supervisor.homeRelayURL()
        let addresses = enabled ? await supervisor.localDirectAddresses() : []
        do {
            _ = try await broker.register(
                pairingEnabled: enabled,
                relayURLHint: enabled ? relay : nil,
                directAddresses: addresses,
                directPorts: enabled ? CmxIrohDirectPorts(localDirectAddresses: addresses) : nil
            )
            guard generationToken == generation,
                  MobileRemoteControlPolicy.allowsIncomingAccess() == enabled else { return }
            registeredIncomingAccess = enabled
            if enabled, let discovery = try? await broker.discover(maximumAge: 0) {
                guard generationToken == generation,
                      MobileRemoteControlPolicy.allowsIncomingAccess() else { return }
                await activateLANAdvertising(discovery: discovery)
            }
            if enabled, publishesPublicHostStatus,
               let identity = try? CmxIrohPeerIdentity(endpointID: binding.endpointIDHex) {
                let hints = relay.flatMap { url in
                    try? CmxIrohPathHint(
                        kind: .relayURL, value: url, source: .native,
                        privacyScope: .publicInternet, observedAt: Date(),
                        expiresAt: Date().addingTimeInterval(1800)
                    )
                }.map { [$0] } ?? []
                MobileHostPublicStatusCache.update(irohIdentity: identity, pathHints: hints)
            }
        } catch {
            // Admission is already closed while publication retries on the next reconcile.
            Self.journal.record("host-runtime", "availability-publish-failed")
        }
    }

    /// Both initial activation and re-enabling hosting restore the same LAN advertisement.
    func activateLANAdvertising(discovery: CmxIrohDiscoveryResponse) async {
        guard !Self.forceRelayOnly, MobileHostService.isListeningEnabled,
              let supervisor = endpointSupervisor, let binding = localBinding,
              let discovered = discovery.bindings.first(where: {
                  $0.endpointID.endpointID == binding.endpointIDHex
              }),
              let metadata = try? CmxIrohBrokerBindingMetadata(
                  bindingID: discovered.bindingID, deviceID: discovered.deviceID,
                  appInstanceID: discovered.appInstanceID,
                  clientNamespace: discovered.clientNamespace, tag: discovered.tag,
                  platform: discovered.platform, endpointID: discovered.endpointID,
                  identityGeneration: discovered.identityGeneration, pathHints: discovered.pathHints
              ) else { return }
        await lanPublisher.activate(
            rendezvous: discovery.lanRendezvous, binding: metadata,
            directAddresses: { await supervisor.localDirectAddresses() }
        )
    }

    /// Creates the account-scoped outgoing session owner, sharing this runtime's endpoint.
    func makeDeviceClient(identity: AuthenticatedSessionIdentity, teamID: String?) -> DeviceIrxClient? {
        guard Self.isEnabled else { return nil }
        let client = DeviceIrxClient(context: { [weak self] in
            guard let self else { throw DeviceLinkError.notConnected }
            return try await self.deviceClientContext(identity: identity, teamID: teamID)
        }, journal: Self.journal)
        outgoingDeviceClient = client
        return client
    }

    /// Borrows the same endpoint identity that the host registered; never registers a second one.
    func deviceClientContext(identity: AuthenticatedSessionIdentity, teamID: String?) async throws -> DeviceIrxClientContext {
        guard Self.isEnabled else { throw DeviceLinkError.notConnected }
        await applyManagedNetworkingPolicy()
        await activationTask?.value
        guard activeAccountID == identity.accountID,
              auth?.authenticatedSessionIdentity == identity,
              auth?.resolvedTeamID == teamID,
              isNetworkingAllowed,
              let broker = brokerService,
              let supervisor = endpointSupervisor,
              let pilot = autopilot,
              let deviceList = deviceListBox,
              let binding = localBinding else { throw DeviceLinkError.notConnected }
        let generation = generationToken
        return DeviceIrxClientContext(
            broker: broker, supervisor: supervisor, relayCredentials: pilot,
            deviceList: deviceList, localBinding: binding,
            allowsDirectPaths: !Self.forceRelayOnly,
            isCurrent: { @MainActor [weak self] in
                self?.generationToken == generation
                    && self?.auth?.authenticatedSessionIdentity == identity
                    && self?.auth?.resolvedTeamID == teamID
                    && self?.isNetworkingAllowed == true
            }
        )
    }
}
