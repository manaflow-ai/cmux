import CmuxFoundation
import Foundation

extension CmuxTuiSurfaceProvider {
    /// The noVNC URL uses only the VM private address. The private network is
    /// the access check, so no public preview token or endpoint is required.
    nonisolated static func privateDesktopURL(privateAddress: String) -> String {
        let base = CmuxInternalHostnames.directPortURL(
            privateAddress: privateAddress,
            port: CmuxTuiSnapshotParser.desktopPort
        )
        return "\(base)/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
    }

    /// Turn a VM-local browser URL into the same URL on the VM private address.
    /// Path, query, fragment, scheme, and port stay unchanged.
    nonisolated static func privateBrowserURL(_ raw: String, privateAddress: String) -> String? {
        guard let parts = URLComponents(string: raw),
              let host = parts.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) else { return nil }
        return CloudPortRoutePlan.privateURL(raw, address: privateAddress)?.absoluteString
    }

    /// Shared Cloud terminal-link conversion for Workspace and Dock containers.
    nonisolated static func cloudTerminalLinkTarget(url: URL, resource: SurfaceResource, privateAddress: String) -> CloudTerminalLinkTarget? {
        guard resource.kind == .terminal, resource.machine.cloudMachineID != nil,
              let rewritten = privateBrowserURL(url.absoluteString, privateAddress: privateAddress),
              let privateURL = URL(string: rewritten) else { return nil }
        return CloudTerminalLinkTarget(url: privateURL)
    }

    /// Add the local URL used when this resource is projected on the Mac.
    nonisolated static func withPrivateBrowserURL(
        _ resource: SurfaceResource,
        privateAddress: String
    ) -> SurfaceResource {
        var updated = resource
        switch resource.kind {
        case .display:
            updated.url = privateDesktopURL(privateAddress: privateAddress)
        case .browser:
            if resource.id.key.hasPrefix("port:"), let port = resource.port {
                updated.url = CmuxInternalHostnames.directPortURL(
                    privateAddress: privateAddress,
                    port: port
                )
            } else if let raw = resource.url {
                updated.url = privateBrowserURL(raw, privateAddress: privateAddress)
            }
        case .terminal:
            break
        }
        return updated
    }

}
