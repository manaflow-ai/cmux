import CmuxSurfaceCatalogModel
import Foundation

/// One guest-issued display resource with a stable slot and noVNC target.
struct CloudGuestDisplay: Decodable, Sendable {
    let id: String
    let number: Int
    let port: Int
    let state: SurfaceLifecycle

    func resource(on machine: SurfaceMachineID, address: String?) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .display, key: id),
            title: number == 1
                ? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop")
                : String(format: String(localized: "cloud.display.numberedTitle", defaultValue: "Desktop %d"), number),
            detail: "noVNC", lifecycle: state, agent: nil, remoteWorkspace: nil,
            port: port, url: address.map { CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: $0, port: port) }
        )
    }
}
