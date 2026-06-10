import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Sidebar tab item settings snapshot and store
private enum SidebarFontSizeProvider {
    static func loadFromGhosttyConfig() async -> CGFloat {
        await Task.detached(priority: .utility) {
            GhosttyConfig.load().sidebarFontSize
        }.value
    }
}

struct SidebarTabItemSettingsSnapshot: Equatable {
    let hidesAllDetails: Bool
    let wrapsWorkspaceTitles: Bool
    let showsWorkspaceDescription: Bool
    let sidebarShortcutHintXOffset: Double
    let sidebarShortcutHintYOffset: Double
    let alwaysShowShortcutHints: Bool
    let sidebarFontScale: CGFloat
    let showsGitBranch: Bool
    let usesVerticalBranchLayout: Bool
    let stacksBranchAndDirectory: Bool
    let usesLastSegmentPath: Bool
    let showsGitBranchIcon: Bool
    let showsSSH: Bool
    let makesPullRequestsClickable: Bool
    let openPullRequestLinksInCmuxBrowser: Bool
    let openPortLinksInCmuxBrowser: Bool
    let showsNotificationMessage: Bool
    let activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle
    let selectionColorHex: String?
    let notificationBadgeColorHex: String?
    let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
    let iMessageModeEnabled: Bool

    init(
        defaults: UserDefaults = .standard,
        sidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize
    ) {
        sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
        sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
        alwaysShowShortcutHints = ShortcutHintDebugSettings.alwaysShowHints()
        sidebarFontScale = SidebarTabItemFontScale.scale(for: sidebarFontSize)
        showsGitBranch = Self.bool(defaults: defaults, key: "sidebarShowGitBranch", defaultValue: true)
        usesVerticalBranchLayout = SidebarBranchLayoutSettings.usesVerticalLayout(defaults: defaults)
        stacksBranchAndDirectory = SidebarBranchDirectoryStackedSettings.isStacked(defaults: defaults)
        usesLastSegmentPath = SidebarPathLastSegmentSettings.isLastSegmentOnly(defaults: defaults)
        showsGitBranchIcon = Self.bool(defaults: defaults, key: "sidebarShowGitBranchIcon", defaultValue: false)
        showsSSH = Self.bool(defaults: defaults, key: "sidebarShowSSH", defaultValue: SidebarWorkspaceDetailDefaults.showSSH)
        makesPullRequestsClickable = SidebarPullRequestClickabilitySettings.isClickable(defaults: defaults)
        openPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(
            defaults: defaults
        )
        openPortLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowser(
            defaults: defaults
        )

        hidesAllDetails = SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
        wrapsWorkspaceTitles = SidebarWorkspaceTitleWrapSettings.wraps(defaults: defaults)
        let showsWorkspaceDescriptionSetting = SidebarWorkspaceDetailSettings.showsWorkspaceDescription(
            defaults: defaults
        )
        showsWorkspaceDescription = SidebarWorkspaceDetailSettings.resolvedWorkspaceDescriptionVisibility(
            showWorkspaceDescription: showsWorkspaceDescriptionSetting,
            hideAllDetails: hidesAllDetails
        )
        let showsNotificationMessageSetting = SidebarWorkspaceDetailSettings.showsNotificationMessage(
            defaults: defaults
        )
        showsNotificationMessage = SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
            showNotificationMessage: showsNotificationMessageSetting,
            hideAllDetails: hidesAllDetails
        )

        let showsMetadata = Self.bool(defaults: defaults, key: "sidebarShowStatusPills", defaultValue: SidebarWorkspaceDetailDefaults.showCustomMetadata)
        let showsLog = Self.bool(defaults: defaults, key: "sidebarShowLog", defaultValue: SidebarWorkspaceDetailDefaults.showLog)
        let showsProgress = Self.bool(defaults: defaults, key: "sidebarShowProgress", defaultValue: SidebarWorkspaceDetailDefaults.showProgress)
        let showsBranchDirectory = Self.bool(defaults: defaults, key: "sidebarShowBranchDirectory", defaultValue: SidebarWorkspaceDetailDefaults.showBranchDirectory)
        let showsPullRequests = Self.bool(defaults: defaults, key: "sidebarShowPullRequest", defaultValue: SidebarWorkspaceDetailDefaults.showPullRequests)
        let showsPorts = Self.bool(defaults: defaults, key: "sidebarShowPorts", defaultValue: SidebarWorkspaceDetailDefaults.showPorts)
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
        iMessageModeEnabled = IMessageModeSettings.isEnabled(defaults: defaults)
    }

    static func bool(
        defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

@MainActor
final class SidebarTabItemSettingsStore: ObservableObject {
    @Published private(set) var snapshot: SidebarTabItemSettingsSnapshot

    let defaults: UserDefaults
    private let sidebarFontSizeProvider: () async -> CGFloat
    var sidebarFontSize: CGFloat
    private var sidebarFontSizeLoadTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var ghosttyConfigObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        initialSidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize,
        sidebarFontSizeProvider: @escaping () async -> CGFloat = SidebarFontSizeProvider.loadFromGhosttyConfig
    ) {
        self.defaults = defaults
        self.sidebarFontSize = GhosttyConfig.clampedSidebarFontSize(initialSidebarFontSize)
        self.sidebarFontSizeProvider = sidebarFontSizeProvider
        self.snapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            sidebarFontSize: sidebarFontSize
        )
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        refreshSidebarFontSize()
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSidebarFontSize()
            }
        }
    }

    deinit {
        sidebarFontSizeLoadTask?.cancel()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let ghosttyConfigObserver {
            NotificationCenter.default.removeObserver(ghosttyConfigObserver)
        }
    }

    private func refreshSnapshot() {
        let nextSnapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            sidebarFontSize: sidebarFontSize
        )
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    private func refreshSidebarFontSize() {
        sidebarFontSizeLoadTask?.cancel()
        sidebarFontSizeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loadedSidebarFontSize = await sidebarFontSizeProvider()
            guard !Task.isCancelled else { return }
            sidebarFontSize = GhosttyConfig.clampedSidebarFontSize(loadedSidebarFontSize)
            refreshSnapshot()
        }
    }
}

enum SidebarTrailingAccessoryWidthPolicy {
    static let closeButtonWidth: CGFloat = 16
}

final class SidebarTabItemContextMenuState: ObservableObject {
    var hasDeferredWorkspaceObservationInvalidation = false
    var pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?
}

