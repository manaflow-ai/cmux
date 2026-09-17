import Foundation

extension CmuxTuiSurfaceProviderRegistry {
    /// The production registry: one hub over the bundled client, shared by every link,
    /// polling only while the activation policy allows background Cloud work.
    convenience init() {
        let hub = CloudTuiClientPaths.clientURL().map { CloudWireGuardHub.production(clientURL: $0) }
        self.init(
            links: CloudMachineLinkManager(hub: hub, operations: AppDelegate.shared?.cloudOperations,
                                           isCloudEnabled: { CloudMachinesFeature.offMainIsEnabled() }),
            wireGuardHub: hub,
            isCloudEnabled: { CloudMachinesFeature.isEnabled },
            allowsBackgroundWork: { CloudActivationPolicy.live().allowsBackgroundCloudWork },
            listPage: {
                guard let client = VMClient.shared else { return nil }
                do {
                    return try await client.listPage()
                } catch {
                    CloudLinkTelemetry.machineListFailed(error: error)
                    return nil
                }
            }
        )
    }

}
