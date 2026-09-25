import Foundation

/// Presentation-only grouping for the Settings sidebar.
///
/// The leaves stay as the existing ``SettingsSectionID`` values so
/// persisted selection, settings-open targets, search entry IDs, scroll
/// anchors, and section implementations keep their current identities.
enum SettingsTaxonomyGroup: String, CaseIterable, Identifiable, Sendable {
    case general
    case terminal
    case workspace
    case sidebarAndDock
    case agentsAndAutomation
    case browserAndFiles
    case remoteAndDevices
    case keyboardAndAdvanced

    /// Stable identity for SwiftUI section iteration.
    var id: Self { self }

    /// Localized heading shown above this group in the default browse sidebar.
    var title: String {
        switch self {
        case .general:
            return String(
                localized: "settings.taxonomy.general",
                defaultValue: "General",
                bundle: .module
            )
        case .terminal:
            // Reuse the existing app catalog entry for the shared label.
            return SettingsSectionID.terminal.title
        case .workspace:
            return String(
                localized: "settings.taxonomy.workspace",
                defaultValue: "Workspace",
                bundle: .module
            )
        case .sidebarAndDock:
            return String(
                localized: "settings.taxonomy.sidebarAndDock",
                defaultValue: "Sidebar & Dock",
                bundle: .module
            )
        case .agentsAndAutomation:
            return String(
                localized: "settings.taxonomy.agentsAndAutomation",
                defaultValue: "Agents & Automation",
                bundle: .module
            )
        case .browserAndFiles:
            return String(
                localized: "settings.taxonomy.browserAndFiles",
                defaultValue: "Browser & Files",
                bundle: .module
            )
        case .remoteAndDevices:
            return String(
                localized: "settings.taxonomy.remoteAndDevices",
                defaultValue: "Remote & Devices",
                bundle: .module
            )
        case .keyboardAndAdvanced:
            return String(
                localized: "settings.taxonomy.keyboardAndAdvanced",
                defaultValue: "Keyboard & Advanced",
                bundle: .module
            )
        }
    }

    /// Existing navigation leaves shown under this presentation category.
    var sections: [SettingsSectionID] {
        switch self {
        case .general:
            return [.account, .app, .sleepyMode]
        case .terminal:
            return [.terminal, .textBox]
        case .workspace:
            return [.workspaceColors]
        case .sidebarAndDock:
            return [.sidebarAppearance, .customSidebars]
        case .agentsAndAutomation:
            return [.automation, .computerUse]
        case .browserAndFiles:
            return [.browser, .browserImport]
        case .remoteAndDevices:
            return [.mobile, .cloudMachines, .networking]
        case .keyboardAndAdvanced:
            return [.globalHotkey, .keyboardShortcuts, .betaFeatures, .settingsJSON, .reset]
        }
    }

    /// All existing navigation leaves in the order used by grouped browsing.
    static var sectionsInDisplayOrder: [SettingsSectionID] {
        allCases.flatMap(\.sections)
    }
}
