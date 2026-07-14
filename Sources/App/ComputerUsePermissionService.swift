import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Owns the macOS permission checks and requests used by computer-use settings and onboarding.
@MainActor
struct ComputerUsePermissionService {
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
