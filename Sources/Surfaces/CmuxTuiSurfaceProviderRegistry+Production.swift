import CmuxCloud
import CmuxCloudTui
import Foundation

extension CmuxTuiSurfaceProviderRegistry {
    /// Kills the hub child synchronously; for `applicationWillTerminate`, where nothing
    /// may await and an orphaned hub would keep a WireGuard session alive after quit.
    nonisolated func terminateWireGuardHubForAppQuit() {
        wireGuardHub?.terminateForAppQuit()
    }

    /// The production registry: one hub over the bundled client, shared by every link,
    /// polling only while the activation policy allows background Cloud work.
    convenience init() {
        let hub = CloudTuiClientPaths.clientURL().map { CloudWireGuardHub.production(clientURL: $0) }
        self.init(
            links: CloudMachineLinkManager(
                hub: hub,
                operations: AppDelegate.shared?.cloudOperations,
                isCloudEnabled: { CloudMachinesFeature.offMainIsEnabled() },
                hostThemeColors: {
                    await MainActor.run {
                        let app = GhosttyApp.shared
                        return (app.defaultForegroundColor.hexString(), app.defaultBackgroundColor.hexString())
                    }
                },
                breadcrumb: { event, fields in StartupBreadcrumbLog.append(event, fields: fields) }
            ),
            sshClipboardWriteTrustStore: AppDelegate.shared?.sshClipboardWriteTrustStore
                ?? SSHClipboardWriteTrustStore(),
            wireGuardHub: hub,
            isCloudEnabled: { CloudMachinesFeature.isEnabled },
            allowsBackgroundWork: {
                CloudActivationPolicy.live().allowsBackgroundCloudWork
            },
            listPage: {
                guard let client = VMClient.shared else { return nil }
                return try? await client.listPage()
            },
            activeTeamID: { AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope?.teamID },
            loadMachineStatus: { machineID, teamID in
                guard let client = VMClient.shared else { throw VMClientError.notSignedIn }
                return try await client.status(id: machineID, teamID: teamID)
            },
            hasCloudSession: { AppDelegate.shared?.auth?.accountFlow.isAuthenticated == true }
        )
    }

}
