import AppKit
import CmuxSettings
import SwiftUI

/// Settings for local computer-use attachment, macOS permissions, menu-bar visibility, and onboarding.
@MainActor
public struct ComputerUseSection: View {
    @State private var enabled: JSONValueModel<Bool>
    @State private var showInMenuBar: JSONValueModel<Bool>
    @State private var accessibilityGranted: Bool
    @State private var screenRecordingGranted: Bool
    @State private var permissionCheckArmed = false

    private let hostActions: SettingsHostActions

    /// Creates the computer-use settings section from the shared JSON store and host permission actions.
    ///
    /// - Parameters:
    ///   - jsonStore: Store backing the two `computerUse.*` preferences.
    ///   - catalog: Catalog containing the computer-use JSON keys.
    ///   - errorLog: Central settings write-error log.
    ///   - hostActions: Host bridge for macOS permission requests and onboarding.
    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.hostActions = hostActions
        _enabled = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.computerUse.enabled,
            errorLog: errorLog
        ))
        _showInMenuBar = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.computerUse.showInMenuBar,
            errorLog: errorLog
        ))
        _accessibilityGranted = State(initialValue: hostActions.computerUseAccessibilityGranted())
        _screenRecordingGranted = State(initialValue: hostActions.computerUseScreenRecordingGranted())
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.computerUse", defaultValue: "Computer Use"),
                section: .computerUse
            )

            SettingsCard {
                SettingsCardRow(
                    configurationReview: .json("computerUse.enabled"),
                    String(localized: "settings.computerUse.enabled", defaultValue: "Enable Computer Use"),
                    subtitle: enabled.current
                        ? String(localized: "settings.computerUse.enabled.subtitleOn", defaultValue: "Supported agent sessions can see and drive apps on this Mac.")
                        : String(localized: "settings.computerUse.enabled.subtitleOff", defaultValue: "New agent launches start without the computer-use tools, including in terminals that are already open.")
                ) {
                    Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityIdentifier("SettingsComputerUseEnabledToggle")
                }
                SettingsCardDivider()
                SettingsCardNote(
                    String(localized: "settings.computerUse.enabled.note", defaultValue: "Computer use runs locally in a separate cmux Computer Use helper. Its permissions and restart lifecycle are independent from cmux. Driver telemetry and update checks are disabled.")
                )
            }

            SettingsCard {
                accessibilityRow
                SettingsCardDivider()
                screenRecordingRow
            }

            SettingsCard {
                SettingsCardRow(
                    configurationReview: .json("computerUse.showInMenuBar"),
                    String(localized: "settings.computerUse.showInMenuBar", defaultValue: "Show Computer Use in Menu Bar"),
                    subtitle: String(localized: "settings.computerUse.showInMenuBar.subtitle", defaultValue: "Show live agent sessions and shortcuts to their terminal and driven app.")
                ) {
                    Toggle("", isOn: Binding(get: { showInMenuBar.current }, set: { showInMenuBar.set($0) }))
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityIdentifier("SettingsComputerUseMenuBarToggle")
                }
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    searchAnchorID: "setting:computerUse:onboarding",
                    String(localized: "settings.computerUse.runOnboarding", defaultValue: "Run Onboarding Again"),
                    subtitle: String(localized: "settings.computerUse.runOnboarding.subtitle", defaultValue: "Review how computer use works and check both macOS permissions.")
                ) {
                    Button(String(localized: "settings.computerUse.runOnboarding.button", defaultValue: "Run…")) {
                        hostActions.runComputerUseOnboarding()
                    }
                    .controlSize(.small)
                }
            }
        }
        .task {
            enabled.startObserving()
            showInMenuBar.startObserving()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard permissionCheckArmed else { return }
            permissionCheckArmed = false
            refreshPermissions()
        }
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:computerUse:permissions",
            String(localized: "settings.computerUse.permission.accessibility", defaultValue: "Accessibility"),
            subtitle: String(localized: "settings.computerUse.permission.accessibility.subtitle", defaultValue: "Lets the local driver inspect and control app interfaces.")
        ) {
            permissionControls(
                granted: accessibilityGranted,
                request: {
                    beginPermissionFlow(hostActions.requestComputerUseAccessibility)
                },
                openSettings: hostActions.openComputerUseAccessibilitySettings
            )
        }
    }

    @ViewBuilder
    private var screenRecordingRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            // No searchAnchorID: the accessibility row carries the shared
            // "setting:computerUse:permissions" anchor; a duplicate SwiftUI id
            // breaks search scroll resolution.
            String(localized: "settings.computerUse.permission.screenRecording", defaultValue: "Screen Recording"),
            subtitle: String(localized: "settings.computerUse.permission.screenRecording.subtitle", defaultValue: "Lets the local driver see app windows and screen content.")
        ) {
            permissionControls(
                granted: screenRecordingGranted,
                request: {
                    beginPermissionFlow(hostActions.requestComputerUseScreenRecording)
                },
                openSettings: hostActions.openComputerUseScreenRecordingSettings
            )
        }
    }

    private func permissionControls(
        granted: Bool,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(
                granted
                    ? String(localized: "settings.computerUse.permission.granted", defaultValue: "Granted")
                    : String(localized: "settings.computerUse.permission.notGranted", defaultValue: "Not Granted")
            )
            .foregroundStyle(.secondary)
            Button(String(localized: "settings.computerUse.permission.grant", defaultValue: "Grant…"), action: request)
                .disabled(granted)
            Button(
                String(
                    localized: "settings.computerUse.permission.openSystemSettings",
                    defaultValue: "Open System Settings"
                ),
                action: openSettings
            )
        }
        .controlSize(.small)
    }

    private func refreshPermissions() {
        Task {
            await hostActions.refreshComputerUsePermissions()
            accessibilityGranted = hostActions.computerUseAccessibilityGranted()
            screenRecordingGranted = hostActions.computerUseScreenRecordingGranted()
        }
    }

    private func beginPermissionFlow(_ action: () -> Void) {
        permissionCheckArmed = true
        action()
    }
}
