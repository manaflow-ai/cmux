import AppKit
import ApplicationServices
import CoreGraphics

/// Screen Recording + Accessibility permission status for the appshot feature.
struct AppshotPermissions: Equatable {
    let screenRecording: Bool
    let accessibility: Bool

    static func current() -> AppshotPermissions {
        AppshotPermissions(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    /// Shows a single explanatory alert when a capture produced nothing —
    /// almost always because Screen Recording and/or Accessibility access is
    /// missing. The alert's buttons register cmux with TCC and open the
    /// matching System Settings pane so the user can grant access. A richer
    /// re-check/re-grant affordance also lives in Settings → Appshots.
    @MainActor
    static func presentMissingPermissionsPromptIfNeeded() {
        let permissions = current()
        // Both granted but capture still failed (e.g. no frontmost window) —
        // there's nothing to re-grant, so just beep.
        guard !permissions.screenRecording || !permissions.accessibility else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "appshot.permissions.alert.title",
            defaultValue: "Allow cmux to capture appshots"
        )
        alert.informativeText = String(
            localized: "appshot.permissions.alert.body",
            defaultValue: "Sending the frontmost window to your agent needs Screen Recording (for the screenshot) and Accessibility (for the window's text). Grant access in System Settings, then press the shortcut again."
        )
        alert.addButton(withTitle: String(
            localized: "appshot.permissions.alert.openScreenRecording",
            defaultValue: "Open Screen Recording"
        ))
        alert.addButton(withTitle: String(
            localized: "appshot.permissions.alert.openAccessibility",
            defaultValue: "Open Accessibility"
        ))
        alert.addButton(withTitle: String(
            localized: "appshot.permissions.alert.cancel",
            defaultValue: "Cancel"
        ))

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            requestScreenRecording()
            openSettingsPane(SettingsPane.screenRecording)
        case .alertSecondButtonReturn:
            requestAccessibility()
            openSettingsPane(SettingsPane.accessibility)
        default:
            break
        }
    }

    /// Registers cmux in the Screen Recording TCC list (and shows the system
    /// prompt on first use) so it appears with a toggle in System Settings.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Triggers the Accessibility trust prompt so cmux appears in the list.
    static func requestAccessibility() {
        // `kAXTrustedCheckOptionPrompt` imports from C as a non-concurrency-safe
        // global `var`; use its documented, stable string value instead.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    enum SettingsPane {
        static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    }

    @MainActor
    static func openSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
