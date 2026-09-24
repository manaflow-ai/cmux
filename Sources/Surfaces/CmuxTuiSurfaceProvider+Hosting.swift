import CmuxSurfaceCatalogModel
import Foundation
import CmuxSettings

@MainActor
extension CmuxTuiSurfaceProvider {
    convenience init(
        summary: VMSummary,
        links: CloudMachineLinkManager,
        catalog: SurfaceCatalog,
        portForwards: CloudHubPortForwarder? = nil,
        attachmentClock: any Clock<Duration> = ContinuousClock(),
        portAccessStore: CloudPortAccessStore? = nil,
        displayCoordinator: CloudDisplayCoordinator? = nil,
        browserPolicy: @escaping @MainActor () -> BrowserURLAllowlistPolicy = { BrowserURLAllowlistPolicy() }
    ) {
        self.init(summary: .cloud(summary), links: links, catalog: catalog,
                  portForwards: portForwards, attachmentClock: attachmentClock,
                  portAccessStore: portAccessStore, displayCoordinator: displayCoordinator,
                  browserPolicy: browserPolicy)
    }
    static func info(from summary: VMSummary, linkState: SurfaceLinkState, linkError: String?, stats: VMStats?, remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil) -> SurfaceMachineInfo {
        info(from: .cloud(summary), linkState: linkState, linkError: linkError, stats: stats, remoteWorkspaces: remoteWorkspaces)
    }

    static func info(from summary: RemoteTuiMachine, linkState: SurfaceLinkState, linkError: String?, stats: VMStats?, remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil) -> SurfaceMachineInfo {
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
            privateAddress: summary.preferredPrivateAddress
        )
    }

}
