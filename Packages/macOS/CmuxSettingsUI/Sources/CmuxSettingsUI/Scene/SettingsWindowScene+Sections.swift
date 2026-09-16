import SwiftUI

/// Constructs the selected Settings category only.
extension SettingsWindowRoot {
    func anchorID(for section: SettingsSectionID) -> String {
        "section:\(section.rawValue)"
    }

    @ViewBuilder
    func sectionPage(_ section: SettingsSectionID) -> some View {
        switch section {
        case .account:
            AccountSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                accountFlow: accountFlow
            )
        case .app:
            AppSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: hostActions
            )
        case .terminal:
            TerminalSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                hostActions: hostActions
            )
        case .textBox:
            TextBoxSection(defaultsStore: defaultsStore, catalog: catalog)
        case .sleepyMode:
            SleepyModeSection(hostActions: hostActions, store: hostActions.sleepyModeStore())
        case .mobile:
            MobileSection(defaultsStore: defaultsStore, catalog: catalog, hostActions: hostActions, pageDrafts: pageDrafts)
        case .cloudMachines:
            // Match the sidebar's managed-policy and rollout gate.
            if isCloudSectionAvailable {
                CloudMachinesSection(hostActions: hostActions)
            }
        case .networking:
            IrohNetworkingSection(hostActions: hostActions)
        case .sidebarAppearance:
            SidebarSection(defaultsStore: defaultsStore, catalog: catalog, hostActions: hostActions)
        case .customSidebars:
            CustomSidebarsSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog
            )
        case .betaFeatures:
            BetaFeaturesSection(defaultsStore: defaultsStore, catalog: catalog)
        case .automation:
            AutomationSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                secretStore: secretStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions,
                pageDrafts: pageDrafts
            )
        case .computerUse:
            ComputerUseSection(
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions
            )
        case .browser:
            BrowserSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: hostActions,
                pageDrafts: pageDrafts
            )
        case .globalHotkey:
            GlobalHotkeySection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog, errorLog: runtime.errorLog,
                hostActions: hostActions,
                defaultShortcutResolver: runtime.shortcutDefaultResolver
            )
        case .keyboardShortcuts:
            KeyboardShortcutsSection(
                jsonStore: jsonStore, userDefaultsStore: defaultsStore,
                catalog: catalog,
                errorLog: runtime.errorLog,
                hostActions: hostActions,
                defaultShortcutResolver: runtime.shortcutDefaultResolver
            )
        case .workspaceColors:
            WorkspaceColorsSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog
            )
        case .settingsJSON:
            SettingsJSONSection(jsonStore: jsonStore, hostActions: hostActions)
        case .reset:
            ResetSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                hostActions: hostActions
            )
        case .browserImport:
            BrowserImportSection(defaultsStore: defaultsStore, catalog: catalog, hostActions: hostActions)
        }
    }
}
