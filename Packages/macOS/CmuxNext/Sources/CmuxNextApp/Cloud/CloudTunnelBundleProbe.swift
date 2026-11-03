import CmuxNextCloudTunnel
import Foundation
import Security

/// Decides once, at launch, whether this build can run the opt-in Cloud Tunnel: it bundles the
/// system extension and is signed with the entitlement to install it. Reads only the bundle and
/// the process's own signature, never SystemExtensions or NetworkExtension.
struct CloudTunnelBundleProbe {
    let bundle: Bundle

    func availability() -> CloudTunnelController.Availability {
        let directory = bundle.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        let extensions = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let url = extensions.first(where: { $0.pathExtension == "systemextension" }),
              let identifier = Bundle(url: url)?.bundleIdentifier else {
            return .unavailable(String(
                localized: "cloudTunnel.unavailable.notBundled",
                defaultValue: "This build of cmux does not include the Cloud Tunnel.",
                table: "Cloud",
                bundle: .module
            ))
        }
        guard Self.hasEntitlement("com.apple.developer.system-extension.install") else {
            return .unavailable(String(
                localized: "cloudTunnel.unavailable.notSigned",
                defaultValue: "This build of cmux is not signed to install the Cloud Tunnel. Use cmux or cmux NIGHTLY.",
                table: "Cloud",
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
