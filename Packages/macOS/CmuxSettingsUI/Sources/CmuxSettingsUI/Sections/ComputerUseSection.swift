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

/// View-independent presentation state for the Computer Use driver row.
public struct ComputerUseDriverRowState: Equatable, Sendable {
    /// Live readiness text shown beside the resolved binary.
    public let statusText: String
    /// Label for the single readiness action.
    public let testButtonTitle: String
    /// Whether the readiness action is currently unavailable.
    public let testDisabled: Bool

    /// Maps the host driver state to readiness labels and Test availability.
    public static func readiness(
        driverState: ComputerUseHostState.DriverState,
        hasResolvedDriver: Bool
    ) -> ComputerUseDriverRowState {
        let statusText: String
        switch driverState {
        case .notFound:
            statusText = String(localized: "settings.computerUse.driver.status.notFound", defaultValue: "Status: not found.")
        case .stopped:
            statusText = String(localized: "settings.computerUse.driver.status.idle", defaultValue: "Status: idle.")
        case .starting:
            statusText = String(localized: "settings.computerUse.driver.status.checking", defaultValue: "Status: checking readiness.")
        case .running(let pid, let serverName, let serverVersion, let toolCount):
            let server = [serverName, serverVersion].compactMap { $0 }.joined(separator: " ")
            if server.isEmpty {
                statusText = String(
                    localized: "settings.computerUse.driver.status.runningDetail.pidOnly",
                    defaultValue: "Status: running. PID \(pid), \(toolCount) tools."
                )
            } else {
                statusText = String(
                    localized: "settings.computerUse.driver.status.runningDetail.server",
                    defaultValue: "Status: running. \(server), PID \(pid), \(toolCount) tools."
                )
            }
        case .failed(let message):
            statusText = String(localized: "settings.computerUse.driver.status.failed", defaultValue: "Status: failed. \(message)")
        }

        let isChecking = driverState == .starting
        return ComputerUseDriverRowState(
            statusText: statusText,
            testButtonTitle: isChecking
                ? String(localized: "settings.computerUse.driver.testing", defaultValue: "Testing…")
                : String(localized: "settings.computerUse.driver.test", defaultValue: "Test"),
            testDisabled: isChecking || !hasResolvedDriver
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
            for await driverState in hostActions.computerUseDriverStateUpdates() {
                apply(driverState: driverState)
            }
        }
        .onChange(of: driverPathModel.current) { _, _ in
            Task {
                await refresh()
            }
        }
    }

    @ViewBuilder
    private var driverCard: some View {
        let rowState = ComputerUseDriverRowState.readiness(
            driverState: hostState.driverState,
            hasResolvedDriver: hostState.resolvedDriver != nil
        )
        SettingsCard {
            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.computerUse.driver.title", defaultValue: "Driver"),
                subtitle: driverSubtitle(statusText: rowState.statusText),
                controlWidth: Self.columnWidth
            ) {
                Button {
                    Task {
                        await hostActions.ensureCuaDriver()
                        await refresh()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if hostState.driverState == .starting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(rowState.testButtonTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(rowState.testDisabled)
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
                searchAnchorID: "setting:computerUse:accessibility",
                grantDisabled: rowState.grantDisabled,
                grantAction: {
                    Task {
                        _ = await hostActions.requestAccessibilityAccess()
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
                searchAnchorID: "setting:computerUse:screen-recording",
                grantDisabled: rowState.grantDisabled,
                grantAction: {
                    Task {
                        _ = await hostActions.requestScreenRecordingAccess()
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

    @ViewBuilder
    private func permissionRow(
        title: String,
        subtitle: String,
        searchAnchorID: String,
        grantDisabled: Bool,
        grantAction: @escaping () -> Void,
        openAction: @escaping () -> Void
    ) -> some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: searchAnchorID,
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

    private func driverSubtitle(statusText: String) -> String {
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
        return "\(pathText) \(statusText)"
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

    private func apply(driverState: ComputerUseHostState.DriverState) {
        hostState = ComputerUseHostState(
            driverState: driverState,
            resolvedDriver: hostState.resolvedDriver,
            triedSources: hostState.triedSources,
            accessibilityGranted: hostState.accessibilityGranted,
            screenRecordingGranted: hostState.screenRecordingGranted,
            screenRecordingRequested: hostState.screenRecordingRequested
        )
    }
}
