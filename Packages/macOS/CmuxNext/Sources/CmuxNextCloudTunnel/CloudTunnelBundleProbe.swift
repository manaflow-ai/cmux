import CmuxNextCompat
public import Foundation
import Security

/// Decides whether this build can run the opt-in Cloud Tunnel: it bundles the system extension
/// and is signed with the entitlement to install it. Reads only the bundle and the process's own
/// signature, never SystemExtensions or NetworkExtension.
///
/// ```swift
/// let tunnel = CloudTunnelController(probe: CloudTunnelBundleProbe(bundle: .main), ...)
/// ```
public struct CloudTunnelBundleProbe: Sendable {
    /// The app bundle whose `Contents/Library/SystemExtensions` holds the extension.
    public let bundleURL: URL

    /// - Parameter bundle: The app bundle to inspect (`.main` in the app).
    public init(bundle: Bundle) {
        bundleURL = bundle.bundleURL
    }

    /// The build's availability. Reads the bundle directory, so it runs off the main thread.
    @concurrent
    public func availability() async -> CloudTunnelController.Availability {
        let directory = bundleURL.appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        let extensions = (try? FileManager.checked.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let url = extensions.first(where: { $0.pathExtension == "systemextension" }),
              let identifier = Bundle(url: url)?.bundleIdentifier else {
            return .unavailable(String(
                localized: "cloudTunnel.unavailable.notBundled",
                defaultValue: "This build of cmux does not include the Cloud Tunnel.",
                bundle: .module
            ))
        }
        guard Self.hasEntitlement("com.apple.developer.system-extension.install") else {
            return .unavailable(String(
                localized: "cloudTunnel.unavailable.notSigned",
                defaultValue: "This build of cmux is not signed to install the Cloud Tunnel. Use cmux or cmux NIGHTLY.",
                bundle: .module
            ))
        }
        return .available(extensionIdentifier: identifier)
    }

    private static func hasEntitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? Bool) == true
    }
}
