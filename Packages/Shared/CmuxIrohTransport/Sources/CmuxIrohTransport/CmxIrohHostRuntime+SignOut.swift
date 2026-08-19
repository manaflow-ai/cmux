extension CmxIrohHostRuntime {
    func performSignOut(
        pendingRevocation: CmxIrohPendingRevocation?,
        bindingAuthorization: CmxIrohBindingRequestAuthorization?,
        requiresNetworkDeactivation: Bool,
        revision: UInt64
    ) async -> CmxIrohHostSignOutPreparation {
        await performSignOutFlow(
            pendingRevocation: pendingRevocation,
            bindingAuthorization: bindingAuthorization,
            revision: revision,
            tearDownNetwork: {
                await self.deactivateNetworkForSignOut(
                    bindingID: pendingRevocation?.bindingID,
                    required: requiresNetworkDeactivation
                )
            }
        )
    }

    func deactivateNetworkForSignOut(
        bindingID: String?,
        required: Bool
    ) async {
        guard required else { return }
        await tearDownComponents(notify: false, preserveBinding: true)
        await handleDeactivation(bindingID)
    }

    func tearDownComponents(
        notify: Bool,
        preserveBinding: Bool = false
    ) async {
        connectivityEventTask?.cancel()
        connectivityEventTask = nil
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        registrationRenewalTask?.cancel()
        registrationRenewalTask = nil
        registrationRefreshPending = false
        registrationRefreshPendingForcesPublication = false
        registrationRefreshEnabled = false
        registrationRefreshFailureCount = 0
        relayActivationTask?.cancel()
        relayActivationTask = nil
        lanPublicationGeneration &+= 1
        lanPublicationTask?.cancel()
        lanPublicationTask = nil
        await endpointServer?.stop()
        endpointServer = nil
        activePathConnections.removeAll(keepingCapacity: false)
        activePathConnectionOrder.removeAll(keepingCapacity: false)
        for task in activePathObservationTasks.values { task.cancel() }
        activePathObservationTasks.removeAll(keepingCapacity: false)
        publishSelectedPathChange()
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        await offlineSessions?.invalidate()
        offlineSessions = nil
        await onlineAdmissionRegistry?.stop()
        onlineAdmissionRegistry = nil
        admissionController = nil
        let bindingID = localBinding?.bindingID
        if !preserveBinding {
            localBinding = nil
            lastRegistrationRefreshState = nil
        }
        endpointAttestation = nil
        lanRendezvous = nil
        authoritativeDiscovery = nil
        await connectivityEngine?.stop()
        connectivityEngine = nil
        if notify { await handleDeactivation(bindingID) }
    }
}
