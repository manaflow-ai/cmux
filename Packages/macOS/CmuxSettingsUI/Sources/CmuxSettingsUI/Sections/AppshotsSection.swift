import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// **Appshots** section — explains the feature and surfaces the
/// Screen Recording + Accessibility permission status with re-check /
/// re-grant affordances.
///
/// The hotkey itself is bound in **Keyboard Shortcuts** ("Send Appshot to
/// Active Agent"); this section is the permission home the feature needs. The
/// permission state is read with the same OS preflight calls the runtime uses
/// (`CGPreflightScreenCaptureAccess` / `AXIsProcessTrusted`) and refreshed on
/// appear and whenever the user taps **Re-check**.
@MainActor
public struct AppshotsSection: View {
    @State private var screenRecordingGranted = false
    @State private var accessibilityGranted = false

    /// Creates the Appshots settings section.
    public init() {}

    /// The section's content: the permission status card plus an explanatory note.
    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.appshots", defaultValue: "Appshots"),
                section: .appshots
            )
            .accessibilityIdentifier("SettingsAppshotsSection")

            permissionsCard

            SettingsCardNote(
                String(
                    localized: "settings.appshots.note",
                    defaultValue: "Press the \"Send Appshot to Active Agent\" shortcut (set it in Keyboard Shortcuts) from any app to capture the frontmost window and send it to your agent. cmux degrades gracefully: with only Accessibility it sends the window's text, and with only Screen Recording it sends the screenshot."
                )
            )
            .accessibilityIdentifier("SettingsAppshotsNote")
        }
        .onAppear { refreshPermissions() }
    }

    @ViewBuilder
    private var permissionsCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.appshots.screenRecording", defaultValue: "Screen Recording"),
                subtitle: screenRecordingGranted
                    ? String(localized: "settings.appshots.screenRecording.granted", defaultValue: "Granted — screenshots are captured.")
                    : String(localized: "settings.appshots.screenRecording.denied", defaultValue: "Not granted — needed to capture the window screenshot.")
            ) {
                Button {
                    requestScreenRecording()
                    open(Self.screenRecordingSettingsURL)
                } label: {
                    Text(String(localized: "settings.appshots.openSystemSettings", defaultValue: "Open System Settings"))
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsAppshotsScreenRecordingButton")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.appshots.accessibility", defaultValue: "Accessibility"),
                subtitle: accessibilityGranted
                    ? String(localized: "settings.appshots.accessibility.granted", defaultValue: "Granted — window text is captured.")
                    : String(localized: "settings.appshots.accessibility.denied", defaultValue: "Not granted — needed to read the window's text.")
            ) {
                Button {
                    requestAccessibility()
                    open(Self.accessibilitySettingsURL)
                } label: {
                    Text(String(localized: "settings.appshots.openSystemSettings", defaultValue: "Open System Settings"))
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsAppshotsAccessibilityButton")
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.appshots.recheck", defaultValue: "Re-check permissions"),
                subtitle: String(localized: "settings.appshots.recheck.subtitle", defaultValue: "Refresh the status after granting access in System Settings.")
            ) {
                Button {
                    refreshPermissions()
                } label: {
                    Text(String(localized: "settings.appshots.recheckButton", defaultValue: "Re-check"))
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsAppshotsRecheckButton")
            }
        }
    }

    private func refreshPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Registers cmux in the Screen Recording TCC list (and shows the system
    /// prompt on first use) so it appears with a toggle in System Settings.
    private func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Triggers the Accessibility trust prompt so cmux appears in the list.
    private func requestAccessibility() {
        // `kAXTrustedCheckOptionPrompt` imports from C as a non-concurrency-safe
        // global `var`; use its documented, stable string value instead.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )
    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
}
