import AppKit
import Foundation

/// Where macOS lets the user allow the cmux Cloud Tunnel system extension.
///
/// macOS 15 moved network system extensions to General › Login Items &
/// Extensions; macOS 14 lists a blocked extension under Privacy & Security.
/// The pane is chosen from the running OS so the button in the Machines panel
/// lands on the right screen on both.
struct SystemExtensionSettingsLink {
    static let loginItemsAndExtensionsPane = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    static let privacyAndSecurityPane = "x-apple.systempreferences:com.apple.preference.security?General"

    /// The System Settings deep link for `macOSMajorVersion`.
    static func url(macOSMajorVersion: Int) -> URL {
        let raw = macOSMajorVersion >= 15 ? loginItemsAndExtensionsPane : privacyAndSecurityPane
        // Both literals are well-formed URLs; a failure here is a programming error.
        return URL(string: raw) ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
    }

    static var current: URL {
        url(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// Opens the pane for the running OS.
    @MainActor
    static func open() {
        NSWorkspace.shared.open(current)
    }
}
