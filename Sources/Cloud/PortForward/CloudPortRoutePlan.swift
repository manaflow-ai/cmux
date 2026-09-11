import CmuxFoundation
import Foundation

/// How a Ports or Desktop row reaches its service, decided from what the
/// machine advertises and nothing else. Pure, so the decision is testable
/// without panes; ``CmuxTuiSurfaceProvider`` executes the plan.
///
/// A machine with a private address is always reached through the user-space
/// WireGuard hub (``CloudHubPortForwarder``): no system VPN, no extension
/// approval, on every build. The signed Network Extension plays no part here.
enum CloudPortRoutePlan: Equatable, Sendable {
    /// Forward `target` through the hub and load `remoteURL` rewritten onto
    /// the loopback listener (path, query, and fragment kept).
    case hubForward(target: CloudPortForwardTarget, remoteURL: String)
    /// No private address: ask the control plane for a tokened preview URL.
    case controlPlanePreview(port: Int)
    case unsupported(String)

    static func plan(
        resource: SurfaceResource,
        privateAddress: String?,
        supportsControlPlanePreviews: Bool
    ) -> CloudPortRoutePlan {
        let desktop = resource.kind == .display
        guard let port = resource.id.forwardedPort ?? resource.port ?? (desktop ? CmuxTuiSnapshotParser.desktopPort : nil) else {
            return .unsupported(String(
                format: String(localized: "cloudTree.port.noPort", defaultValue: "%@ has no port to open."),
                resource.id.rawValue
            ))
        }
        if let privateAddress = privateAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !privateAddress.isEmpty {
            let remoteURL = resource.url ?? (
                desktop
                    ? CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: privateAddress)
                    : CmuxInternalHostnames.directPortURL(privateAddress: privateAddress, port: port)
            )
            return .hubForward(target: CloudPortForwardTarget(host: privateAddress, port: port), remoteURL: remoteURL)
        }
        if supportsControlPlanePreviews {
            return .controlPlanePreview(port: port)
        }
        return .unsupported(String(
            format: String(
                localized: "cloudTree.port.noPrivateAddress",
                defaultValue: "%@ has no private network address yet; refresh the machine list and retry."
            ),
            resource.machine.rawValue
        ))
    }

    /// `remoteURL` with its host and port replaced by the loopback listener.
    static func localURL(rewriting remoteURL: String, toLoopbackPort localPort: UInt16) -> URL? {
        guard var parts = URLComponents(string: remoteURL) else { return nil }
        if parts.scheme == nil { parts.scheme = "http" }
        // A raw TCP relay carries no TLS routing: the client would validate the
        // VM's certificate against 127.0.0.1 and send no usable SNI, so only
        // plain HTTP is rewritten onto the loopback listener.
        guard parts.scheme?.lowercased() == "http" else { return nil }
        parts.host = "127.0.0.1"
        parts.port = Int(localPort)
        return parts.url
    }
}
