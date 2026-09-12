import CmuxFoundation
import Foundation

/// Browser opens always target the VM's private address. A missing address is
/// an unavailable route; it must never create a local listener or public preview.
enum CloudPortRoutePlan: Equatable, Sendable {
    case privateDirect(remoteURL: String)
    case unsupported(String)

    static func plan(resource: SurfaceResource, privateAddress: String?) -> CloudPortRoutePlan {
        let desktop = resource.kind == .display
        guard let port = resource.id.forwardedPort ?? resource.port ?? (desktop ? CmuxTuiSnapshotParser.desktopPort : nil),
              (1...65_535).contains(port) else {
            return .unsupported(String(format: String(localized: "cloudTree.port.noPort", defaultValue: "%@ has no port to open."), resource.id.rawValue))
        }
        guard let address = privateAddress, !address.isEmpty else {
            return .unsupported(String(format: String(localized: "cloudTree.port.noPrivateAddress", defaultValue: "%@ has no private network address yet; refresh the machine list and retry."), resource.machine.rawValue))
        }
        let raw = resource.url ?? (desktop
            ? CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: address)
            : CmuxInternalHostnames.directPortURL(privateAddress: address, port: port))
        guard let url = privateURL(raw, address: address) else {
            return .unsupported(String(localized: "cloud.portAccess.invalidURL", defaultValue: "This port does not have a valid HTTP or HTTPS address."))
        }
        return .privateDirect(remoteURL: url.absoluteString)
    }

    static func privateURL(_ raw: String, address: String) -> URL? {
        guard var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = IPNetworkPrefix.routeHost("http://\(address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address)"),
              BrowserInsecureHTTPSettings.isPrivateNetworkHost(host),
              !["127.0.0.1", "::1", "0.0.0.0", "::"].contains(host) else { return nil }
        parts.host = host.contains(":") ? "[\(host)]" : host
        return parts.url
    }

    /// Only an explicit Forward action may use this URL transformation.
    static func localURL(rewriting remoteURL: String, toLoopbackPort localPort: UInt16) -> URL? {
        guard localPort > 0, var parts = URLComponents(string: remoteURL), parts.scheme?.lowercased() == "http" else { return nil }
        parts.host = "127.0.0.1"
        parts.port = Int(localPort)
        return parts.url
    }
}
