import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation

/// One guest-issued display resource with a stable slot and noVNC target.
public struct CloudGuestDisplay: Decodable, Sendable {
    public let id: String
    public let number: Int
    public let port: Int
    public let state: SurfaceLifecycle

    public func resource(on machine: SurfaceMachineID, address: String?) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .display, key: id),
            title: number == 1
                ? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop")
                : String(format: String(localized: "cloud.display.numberedTitle", defaultValue: "Desktop %d"), number),
            detail: "noVNC", lifecycle: state, agent: nil, remoteWorkspace: nil,
            port: port, url: address.map { Self.privateDesktopURL(privateAddress: $0, port: port) }
        )
    }

    /// The noVNC page for a guest display reached directly over the machine's private address.
    ///
    /// - Parameters:
    ///   - privateAddress: The machine's private network address.
    ///   - port: The display's noVNC port; defaults to the primary desktop port.
    /// - Returns: The noVNC URL string with websockify, autoconnect, and reconnect options set.
    public static func privateDesktopURL(privateAddress: String, port: Int = CmuxTuiSnapshotParser.desktopPort) -> String {
        let base = CmuxInternalHostnames().directPortURL(privateAddress: privateAddress, port: port)
        return "\(base)/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
    }
}
