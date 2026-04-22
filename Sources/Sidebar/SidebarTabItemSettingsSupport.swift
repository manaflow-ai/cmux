import Combine
import Foundation

struct SidebarTabItemSettingsSnapshot: Equatable {
    let sidebarShortcutHintXOffset: Double
    let sidebarShortcutHintYOffset: Double
    let alwaysShowShortcutHints: Bool
    let showsGitBranch: Bool
    let usesVerticalBranchLayout: Bool
    let showsGitBranchIcon: Bool
    let showsSSH: Bool
    let openPullRequestLinksInCmuxBrowser: Bool
    let openPortLinksInCmuxBrowser: Bool
    let showsNotificationMessage: Bool
    let activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle
    let selectionColorHex: String?
    let notificationBadgeColorHex: String?
    let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility

    init(defaults: UserDefaults = .standard) {
        sidebarShortcutHintXOffset = Self.double(
            defaults: defaults,
            key: ShortcutHintDebugSettings.sidebarHintXKey,
            defaultValue: ShortcutHintDebugSettings.defaultSidebarHintX
        )
        sidebarShortcutHintYOffset = Self.double(
            defaults: defaults,
            key: ShortcutHintDebugSettings.sidebarHintYKey,
            defaultValue: ShortcutHintDebugSettings.defaultSidebarHintY
        )
        alwaysShowShortcutHints = Self.bool(
            defaults: defaults,
            key: ShortcutHintDebugSettings.alwaysShowHintsKey,
            defaultValue: ShortcutHintDebugSettings.defaultAlwaysShowHints
        )
        showsGitBranch = Self.bool(defaults: defaults, key: "sidebarShowGitBranch", defaultValue: true)
        usesVerticalBranchLayout = SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults)
        showsGitBranchIcon = Self.bool(defaults: defaults, key: "sidebarShowGitBranchIcon", defaultValue: false)
        showsSSH = Self.bool(defaults: defaults, key: "sidebarShowSSH", defaultValue: true)
        openPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(
            defaults: defaults
        )
        openPortLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowser(
            defaults: defaults
        )

        let hidesAllDetails = SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
        let showsNotificationMessageSetting = SidebarWorkspaceDetailSettings.showsNotificationMessage(
            defaults: defaults
        )
        showsNotificationMessage = SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
            showNotificationMessage: showsNotificationMessageSetting,
            hideAllDetails: hidesAllDetails
        )

        let showsMetadata = Self.bool(defaults: defaults, key: "sidebarShowStatusPills", defaultValue: true)
        let showsLog = Self.bool(defaults: defaults, key: "sidebarShowLog", defaultValue: true)
        let showsProgress = Self.bool(defaults: defaults, key: "sidebarShowProgress", defaultValue: true)
        let showsBranchDirectory = Self.bool(defaults: defaults, key: "sidebarShowBranchDirectory", defaultValue: true)
        let showsPullRequests = Self.bool(defaults: defaults, key: "sidebarShowPullRequest", defaultValue: true)
        let showsPorts = Self.bool(defaults: defaults, key: "sidebarShowPorts", defaultValue: true)
        visibleAuxiliaryDetails = SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: showsMetadata,
            showLog: showsLog,
            showProgress: showsProgress,
            showBranchDirectory: showsBranchDirectory,
            showPullRequests: showsPullRequests,
            showPorts: showsPorts,
            hideAllDetails: hidesAllDetails
        )

        activeTabIndicatorStyle = SidebarActiveTabIndicatorSettings.current(defaults: defaults)
        selectionColorHex = defaults.string(forKey: "sidebarSelectionColorHex")
        notificationBadgeColorHex = defaults.string(forKey: "sidebarNotificationBadgeColorHex")
    }

    private static func bool(
        defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func double(
        defaults: UserDefaults,
        key: String,
        defaultValue: Double
    ) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return defaultValue }
        return value.doubleValue
    }
}

@MainActor
final class SidebarTabItemSettingsStore: ObservableObject {
    @Published private(set) var snapshot: SidebarTabItemSettingsSnapshot

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func refreshSnapshot() {
        let nextSnapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }
}

struct SidebarTabItemPresentationSnapshot: Equatable {
    let tabId: UUID
    let unreadCount: Int
    let latestNotificationText: String?
    let showsModifierShortcutHints: Bool
}
