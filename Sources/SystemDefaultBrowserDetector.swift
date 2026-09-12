import AppKit
import CmuxFoundation

/// Detects whether the user's system default browser is Chromium-family.
///
/// The lookup answers the `.auto` engine preference at pane-creation time, so
/// a Chrome user gets the Chromium engine and a Safari user gets WebKit
/// without either configuring anything. The bundle-identifier mapping itself
/// lives in ``BrowserEngineDefaultChoice/isChromiumFamilyBundleIdentifier(_:)``
/// so it stays unit-testable without AppKit.
enum SystemDefaultBrowserDetector {
    /// Returns `true` when the default HTTP handler is a Chromium-family browser.
    static func isChromiumFamily() -> Bool {
        guard let probeURL = URL(string: "https://example.com"),
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else {
            return false
        }
        return BrowserEngineDefaultChoice.isChromiumFamilyBundleIdentifier(
            Bundle(url: applicationURL)?.bundleIdentifier
        )
    }
}
