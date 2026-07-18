import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Owns the cmux process's macOS permission checks and requests for computer use.
///
/// The bundled driver always runs in embedded mode, so macOS attributes both
/// permissions to cmux itself. Keeping checks and requests in this process makes
/// the status shown in Settings and onboarding authoritative.
@MainActor
final class ComputerUsePermissionService {
    var applicationName: String {
        let candidate = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? String(localized: "about.appName", defaultValue: "cmux")
            : trimmed
    }

    func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func status() -> (accessibility: Bool, screenRecording: Bool) {
        (accessibilityGranted(), screenRecordingGranted())
    }

    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()
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
