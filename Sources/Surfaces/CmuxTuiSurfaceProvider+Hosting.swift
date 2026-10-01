import CmuxAuthRuntime
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import CmuxSettings

@MainActor
extension CmuxTuiSurfaceProvider {
    convenience init(
        summary: VMSummary,
        fileAccessTeamScope: AuthenticatedTeamScope? = nil,
        ownerTeamID: String? = nil,
        links: CloudMachineLinkManager,
        catalog: SurfaceCatalog,
        portForwards: CloudHubPortForwarder? = nil,
        attachmentClock: any Clock<Duration> = ContinuousClock(),
        portAccessStore: CloudPortAccessStore? = nil,
        displayCoordinator: CloudDisplayCoordinator? = nil,
        browserPolicy: @escaping @MainActor () -> BrowserURLAllowlistPolicy = { BrowserURLAllowlistPolicy() },
        loadPortSummary: (@MainActor (String) async throws -> VMSummary)? = nil
    ) {
        self.init(summary: .cloud(summary), fileAccessTeamScope: fileAccessTeamScope, ownerTeamID: ownerTeamID,
                  links: links, catalog: catalog,
                  portForwards: portForwards, attachmentClock: attachmentClock,
                  portAccessStore: portAccessStore, displayCoordinator: displayCoordinator,
                  browserPolicy: browserPolicy, loadPortSummary: loadPortSummary)
    }
    static func info(from summary: VMSummary, linkState: SurfaceLinkState, linkError: String?, stats: VMStats?, remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil, portDiscoveryState: CloudPortDiscoveryState = .notRequested) -> SurfaceMachineInfo {
        info(from: .cloud(summary), linkState: linkState, linkError: linkError, stats: stats, remoteWorkspaces: remoteWorkspaces, portDiscoveryState: portDiscoveryState)
    }

    static func info(from summary: RemoteTuiMachine, linkState: SurfaceLinkState, linkError: String?, stats: VMStats?, remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil, portDiscoveryState: CloudPortDiscoveryState = .notRequested) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: summary.machine,
            name: summary.preferredName,
            status: summary.status,
            image: summary.image,
            hasDesktop: summary.resolvedKind.hasDesktop,
            memoryMb: stats?.memoryTotalMb,
            diskMb: stats?.diskTotalMb,
            linkState: linkState,
            linkError: linkError,
            cpuPercent: stats?.cpuPercent,
            memoryUsedMb: stats?.memoryUsedMb,
            diskUsedMb: stats?.diskUsedMb,
            remoteWorkspaces: remoteWorkspaces,
            privateAddress: summary.preferredPrivateAddress,
            portDiscoveryState: portDiscoveryState
        )
    }

}
