import AppKit
import Foundation

/// Where macOS lets the user allow the cmux Cloud Tunnel system extension.
///
/// macOS 15 moved network system extensions to General › Login Items &
/// Extensions; macOS 14 lists a blocked extension under Privacy & Security.
/// The pane is chosen from the running OS so the button in the Machines panel
/// lands on the right screen on both.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public struct SystemExtensionSettingsLink: Sendable {
    public static let loginItemsAndExtensionsPane = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    public static let privacyAndSecurityPane = "x-apple.systempreferences:com.apple.preference.security?General"

    /// The System Settings deep link for `macOSMajorVersion`.
    public static func url(macOSMajorVersion: Int) -> URL {
        let raw = macOSMajorVersion >= 15 ? loginItemsAndExtensionsPane : privacyAndSecurityPane
        // Both literals are well-formed URLs; a failure here is a programming error.
        return URL(string: raw) ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
    }

    public static var current: URL {
        url(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// Opens the pane for the running OS.
    @MainActor
    public static func open() {
        NSWorkspace.shared.open(current)
    }
}
