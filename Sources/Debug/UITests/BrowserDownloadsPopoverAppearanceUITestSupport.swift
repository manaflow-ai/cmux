#if DEBUG
import AppKit
import CmuxTestSupport
import Foundation
import SwiftUI

/// Debug-only state and capture support for the downloads-popover appearance UI test.
@MainActor
struct BrowserDownloadsPopoverAppearanceUITestSupport {
    private static let probePathEnvironmentKey = "CMUX_UI_TEST_DOWNLOADS_POPOVER_APPEARANCE_PATH"
    private static let fixturePathEnvironmentKey = "CMUX_UI_TEST_DOWNLOADS_POPOVER_FIXTURE_PATH"

    private let environment: [String: String]
    private let sink: UITestCaptureSink

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        self.sink = UITestCaptureSink(environment: environment)
    }

    var isEnabled: Bool {
        configuredPath(for: Self.probePathEnvironmentKey) != nil
    }

    var fixtureDownload: BrowserDownloadRecord? {
        guard isEnabled,
              let fixturePath = configuredPath(for: Self.fixturePathEnvironmentKey) else { return nil }
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        return BrowserDownloadRecord(
            id: "ui-test-downloads-popover-appearance",
            filename: fixtureURL.lastPathComponent,
            fileURL: fixtureURL,
            state: .saved,
            byteCount: 5_400
        )
    }

    func shouldPresent(for colorScheme: ColorScheme) -> Bool {
        isEnabled && colorScheme == .light
    }

    func record(window: NSWindow, contentColorScheme: ColorScheme) {
        writeSnapshot(window: window, contentColorScheme: contentColorScheme)
    }

    private func writeSnapshot(window: NSWindow, contentColorScheme: ColorScheme) {
        let windowAppearance: String
        switch window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .aqua:
            windowAppearance = "light"
        case .darkAqua:
            windowAppearance = "dark"
        default:
            windowAppearance = "unknown"
        }

        let contentScheme: String
        switch contentColorScheme {
        case .light:
            contentScheme = "light"
        case .dark:
            contentScheme = "dark"
        @unknown default:
            contentScheme = "unknown"
        }

        _ = sink.mutateJSONObjectIfConfigured(envKey: Self.probePathEnvironmentKey) { payload in
            payload["contentColorScheme"] = contentScheme
            payload["windowAppearance"] = windowAppearance
            payload["windowClass"] = String(describing: type(of: window))
            payload["windowVisible"] = window.isVisible ? "true" : "false"
        }
    }

    private func configuredPath(for key: String) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
#endif
