import CmuxFoundation
import CmuxSettings
import SwiftUI

/// View-independent presentation state for a Computer Use permission row.
public struct ComputerUsePermissionRowState: Equatable, Sendable {
    /// Status text shown under the permission name.
    public let statusText: String
    /// Whether the Grant button should be disabled.
    public let grantDisabled: Bool
    /// Optional hint shown below the row.
    public let hintText: String?

    /// Creates a permission row state.
    public init(statusText: String, grantDisabled: Bool, hintText: String?) {
        self.statusText = statusText
        self.grantDisabled = grantDisabled
        self.hintText = hintText
    }

    /// Maps Accessibility permission state to display labels.
    public static func accessibility(granted: Bool) -> ComputerUsePermissionRowState {
        ComputerUsePermissionRowState(
            statusText: granted
                ? String(localized: "settings.computerUse.permission.granted", defaultValue: "Granted")
                : String(localized: "settings.computerUse.permission.notGranted", defaultValue: "Not granted"),
            grantDisabled: granted,
            hintText: nil
        )
    }

    /// Maps Screen Recording permission state to display labels.
    public static func screenRecording(granted: Bool, requested: Bool) -> ComputerUsePermissionRowState {
        ComputerUsePermissionRowState(
            statusText: granted
                ? String(localized: "settings.computerUse.permission.granted", defaultValue: "Granted")
                : String(localized: "settings.computerUse.permission.notGranted", defaultValue: "Not granted"),
            grantDisabled: granted,
            hintText: requested && !granted
                ? String(localized: "settings.computerUse.screenRecording.relaunchHint", defaultValue: "After granting Screen Recording, relaunch cmux for the permission to take effect.")
                : nil
        )
    }
}

@MainActor
public struct ComputerUseSection: View {
    private let hostActions: SettingsHostActions
    private static let columnWidth: CGFloat = 220

    @State private var driverPathModel: JSONValueModel<String>
    @State private var hostState: ComputerUseHostState = .unavailable
    @State private var isRefreshing = false

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        _driverPathModel = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.computerUse.driverPath,
            errorLog: errorLog
        ))
        self.hostActions = hostActions
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.computerUse", defaultValue: "Computer Use"), section: .computerUse)
            driverCard
            accessibilityCard
            screenRecordingCard
        }
        .task {
            driverPathModel.startObserving()
            await refresh()
        }
    }

    @ViewBuilder
    private var driverCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.computerUse.driver.title", defaultValue: "Driver"),
                subtitle: driverSubtitle,
                controlWidth: Self.columnWidth
            ) {
                driverButton
            }

            if case let .running(pid, serverName, serverVersion, toolCount) = hostState.driverState {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    String(localized: "settings.computerUse.driver.runningInfo", defaultValue: "Running Info"),
                    subtitle: runningSubtitle(pid: pid, serverName: serverName, serverVersion: serverVersion, toolCount: toolCount),
                    controlWidth: Self.columnWidth
                ) {
                    Text(String(localized: "settings.computerUse.driver.toolCount", defaultValue: "\(toolCount) tools"))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCardDivider()
            VStack(alignment: .leading, spacing: 6) {
                SettingsTextFieldRow(
                    model: driverPathModel,
                    title: String(localized: "settings.computerUse.driver.path", defaultValue: "Driver Path"),
                    placeholder: String(localized: "settings.computerUse.driver.path.placeholder", defaultValue: "/path/to/cua-driver")
                )
                .settingsSearchAnchors(["setting:computerUse:driver-path"])
                Text(String(localized: "settings.computerUse.driver.path.note", defaultValue: "Optional development override. Leave empty to try the environment variable, app helper, then /Applications/CuaDriver.app."))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var accessibilityCard: some View {
        let rowState = ComputerUsePermissionRowState.accessibility(granted: hostState.accessibilityGranted)
        SettingsCard {
            permissionRow(
                title: String(localized: "settings.computerUse.accessibility.title", defaultValue: "Accessibility"),
                subtitle: rowState.statusText,
                grantDisabled: rowState.grantDisabled,
                grantAction: {
                    Task {
                        await hostActions.requestAccessibilityAccess()
                        await refresh()
                    }
                },
                openAction: {
                    hostActions.openPrivacyPane(anchor: .accessibility)
                }
            )
        }
    }

    @ViewBuilder
    private var screenRecordingCard: some View {
        let rowState = ComputerUsePermissionRowState.screenRecording(
            granted: hostState.screenRecordingGranted,
            requested: hostState.screenRecordingRequested
        )
        SettingsCard {
            permissionRow(
                title: String(localized: "settings.computerUse.screenRecording.title", defaultValue: "Screen Recording"),
                subtitle: rowState.statusText,
                grantDisabled: rowState.grantDisabled,
                grantAction: {
                    Task {
                        await hostActions.requestScreenRecordingAccess()
                        await refresh()
                    }
                },
                openAction: {
                    hostActions.openPrivacyPane(anchor: .screenRecording)
                }
            )
            if let hintText = rowState.hintText {
                SettingsCardDivider()
                SettingsCardNote(hintText)
            }
        }
    }

    private var driverButton: some View {
        Group {
            switch hostState.driverState {
            case .starting:
                ProgressView()
                    .controlSize(.small)
            case .running:
                Button(String(localized: "settings.computerUse.driver.stop", defaultValue: "Stop")) {
                    Task {
                        await hostActions.stopCuaDriver()
                        await refresh()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .notFound:
                Button(String(localized: "settings.computerUse.driver.start", defaultValue: "Start")) {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
            case .stopped, .failed:
                Button(String(localized: "settings.computerUse.driver.start", defaultValue: "Start")) {
                    Task {
                        await hostActions.startCuaDriver()
                        await refresh()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(hostState.resolvedDriver == nil)
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        subtitle: String,
        grantDisabled: Bool,
        grantAction: @escaping () -> Void,
        openAction: @escaping () -> Void
    ) -> some View {
        SettingsCardRow(
            configurationReview: .action,
            title,
            subtitle: subtitle,
            controlWidth: Self.columnWidth
        ) {
            HStack(spacing: 8) {
                Button(String(localized: "settings.computerUse.permission.grant", defaultValue: "Grant")) {
                    grantAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(grantDisabled)

                Button(String(localized: "settings.computerUse.permission.openSystemSettings", defaultValue: "Open System Settings")) {
                    openAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var driverSubtitle: String {
        let pathText: String
        if let resolved = hostState.resolvedDriver {
            pathText = String(
                localized: "settings.computerUse.driver.resolved",
                defaultValue: "Resolved \(resolved.path) from \(sourceLabel(resolved.source))."
            )
        } else {
            let sources = hostState.triedSources.map(sourceLabel(_:)).joined(separator: ", ")
            pathText = String(
                localized: "settings.computerUse.driver.notFound",
                defaultValue: "Not found. Tried \(sources)."
            )
        }
        return "\(pathText) \(driverStatusText)"
    }

    private var driverStatusText: String {
        switch hostState.driverState {
        case .notFound:
            return String(localized: "settings.computerUse.driver.status.notFound", defaultValue: "Status: not found.")
        case .stopped:
            return String(localized: "settings.computerUse.driver.status.stopped", defaultValue: "Status: stopped.")
        case .starting:
            return String(localized: "settings.computerUse.driver.status.starting", defaultValue: "Status: starting.")
        case .running:
            return String(localized: "settings.computerUse.driver.status.running", defaultValue: "Status: running.")
        case .failed(let message):
            return String(localized: "settings.computerUse.driver.status.failed", defaultValue: "Status: failed. \(message)")
        }
    }

    private func runningSubtitle(pid: Int32, serverName: String?, serverVersion: String?, toolCount: Int) -> String {
        let server = [serverName, serverVersion].compactMap { $0 }.joined(separator: " ")
        if server.isEmpty {
            return String(localized: "settings.computerUse.driver.runningInfo.pidOnly", defaultValue: "PID \(pid), \(toolCount) tools.")
        }
        return String(localized: "settings.computerUse.driver.runningInfo.server", defaultValue: "\(server), PID \(pid), \(toolCount) tools.")
    }

    private func sourceLabel(_ source: ComputerUseDriverSource) -> String {
        switch source {
        case .setting:
            return String(localized: "settings.computerUse.driver.source.setting", defaultValue: "computerUse.driverPath")
        case .environment:
            return String(localized: "settings.computerUse.driver.source.environment", defaultValue: "CMUX_CUA_DRIVER_PATH")
        case .bundleHelper:
            return String(localized: "settings.computerUse.driver.source.bundleHelper", defaultValue: "app helper")
        case .applications:
            return String(localized: "settings.computerUse.driver.source.applications", defaultValue: "/Applications/CuaDriver.app")
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        hostState = await hostActions.computerUseState()
        isRefreshing = false
    }
}
