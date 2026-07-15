import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Owns the macOS permission checks and requests used by computer-use settings and onboarding.
@MainActor
struct ComputerUsePermissionService {
    /// Display name of the bundled computer-use helper app the user grants
    /// permissions to. It carries its own bundle id (`com.cmuxterm.computer-use`)
    /// and TCC identity, so Accessibility / Screen Recording appear under this name
    /// in System Settings — separate from cmux.
    static let helperAppName = "cmux Computer Use"

    /// URL of the bundled `cmux Computer Use.app` helper inside cmux.app, when
    /// present. It lives under `Contents/Library/` so onboarding can reveal it in
    /// Finder for drag-and-drop into the System Settings permission lists.
    var helperAppURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/\(Self.helperAppName).app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Selects the helper app in Finder so the user can drag it into a System
    /// Settings permission list. No-op until the helper is bundled.
    func revealHelperInFinder() {
        guard let helperAppURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([helperAppURL])
    }

    func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func openScreenRecordingSettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    private func openSystemSettings(_ deepLink: String) {
        guard let url = URL(string: deepLink) else { return }
        NSWorkspace.shared.open(url)
    }
}
