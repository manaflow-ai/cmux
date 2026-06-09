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

struct SidebarResizerAccessibilityModifier: ViewModifier {
    let accessibilityIdentifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}

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

    private static func bool(
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

enum CmuxExtensionSidebarSelection {
    static let defaultsKey = "cmuxExtensionSidebar.providerId"
    static let selectedExtensionNameDefaultsKey = "cmuxExtensionSidebar.selectedExtensionName"
    static let defaultProviderId = CmuxSidebarProviderDescriptor.defaultWorkspacesID
    static let hostedExtensionsProviderId = "cmux.sidebar.extensions"

    /// Synchronous read of the experimental Extensions flag for the on-demand
    /// AppKit/static paths (the toggle menu, the command-palette builder, the
    /// extensions-browser opener) that have no `SettingsRuntime` in scope and
    /// run outside the SwiftUI update cycle.
    ///
    /// SwiftUI views bind reactively via `@LiveSetting(\.betaFeatures.extensions)`.
    /// This synchronous read resolves the same catalog key
    /// (`BetaFeaturesCatalogSection.extensions`) against `UserDefaults`, which is
    /// the same suite and key the store persists to, so the catalog stays the
    /// single definition of the key, decode, and default.
    static var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.extensions
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    static var providers: [any CmuxSidebarProvider] {
        SidebarExamples.providers
    }

    // MARK: - Custom sidebars (beta)

    /// Provider-id prefix for user/agent-authored custom sidebars. The
    /// suffix after the prefix is the sidebar's file base name.
    static let customSidebarProviderPrefix = "cmux.sidebar.custom."

    /// Synchronous read of the experimental custom-sidebars flag, mirroring
    /// ``isEnabled`` for the AppKit/static paths (the picker menu).
    static var customSidebarsEnabled: Bool {
        let key = SettingCatalog().betaFeatures.customSidebars
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Directory custom sidebars are authored into.
    static var customSidebarsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/sidebars", isDirectory: true)
    }

    /// One provider descriptor per `<name>.swift`/`<name>.json` file in the
    /// sidebars directory (`.swift` preferred when both exist), titled by the
    /// file's base name.
    static var customSidebarDescriptors: [CmuxSidebarProviderDescriptor] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: customSidebarsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var extensionByName: [String: String] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "swift" || ext == "json" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if extensionByName[name] == "swift" { continue }
            extensionByName[name] = ext
        }
        return extensionByName.keys.sorted().map { name in
            CmuxSidebarProviderDescriptor(
                id: customSidebarProviderPrefix + name,
                title: CmuxSidebarProviderLocalizedText(key: "sidebar.provider.custom.\(name)", defaultValue: name),
                subtitle: CmuxSidebarProviderLocalizedText(
                    key: "sidebar.provider.custom.subtitle",
                    defaultValue: String(localized: "sidebar.provider.custom.subtitle", defaultValue: "Custom sidebar")
                ),
                systemImageName: "wand.and.stars",
                isHostProvided: false
            )
        }
    }

    /// Resolves a custom-sidebar provider id to its backing file URL
    /// (`.swift` preferred), or `nil` if neither file exists.
    static func customSidebarFileURL(forProviderId providerId: String) -> URL? {
        guard providerId.hasPrefix(customSidebarProviderPrefix) else { return nil }
        let name = String(providerId.dropFirst(customSidebarProviderPrefix.count))
        let swiftURL = customSidebarsDirectory.appendingPathComponent("\(name).swift")
        if FileManager.default.fileExists(atPath: swiftURL.path) { return swiftURL }
        let jsonURL = customSidebarsDirectory.appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: jsonURL.path) { return jsonURL }
        return nil
    }

    /// The always-available built-in views: the default workspaces sidebar plus
    /// the bundled preset providers (Project Worktrees, Attention Queue, Dev
    /// Servers, Last Prompt, Super Compact, Browser Stack). These ship
    /// independently of the experimental Extensions feature, so they stay in
    /// the switcher menu regardless of the beta flag.
    static var builtInDescriptors: [CmuxSidebarProviderDescriptor] {
        [.defaultWorkspaces] + providers.map { $0.descriptor }
    }

    /// Descriptors offered in the switcher menu and command palette. The hosted
    /// extension entry belongs to the experimental Extensions feature, so it is
    /// only offered while that beta is enabled; the built-in views are always
    /// offered.
    static var descriptors: [CmuxSidebarProviderDescriptor] {
        var result = isEnabled ? builtInDescriptors + [hostedExtensionsDescriptor] : builtInDescriptors
        if customSidebarsEnabled { result += customSidebarDescriptors }
        return result
    }

    /// Every descriptor that can ever be selected, ignoring feature gates. Used
    /// to register command-palette handlers so a runtime flag flip always has a
    /// handler to invoke; what is *shown* uses ``descriptors``.
    static var allDescriptors: [CmuxSidebarProviderDescriptor] {
        builtInDescriptors + [hostedExtensionsDescriptor] + customSidebarDescriptors
    }

    static var hostedExtensionsDescriptor: CmuxSidebarProviderDescriptor {
        let selectedName = UserDefaults.standard.string(forKey: selectedExtensionNameDefaultsKey)?.nilIfEmpty
        return CmuxSidebarProviderDescriptor(
            id: hostedExtensionsProviderId,
            title: CmuxSidebarProviderLocalizedText(
                key: "sidebar.provider.extensions.title",
                defaultValue: selectedName ?? String(localized: "sidebar.provider.extensions.title", defaultValue: "Extension Sidebar")
            ),
            subtitle: CmuxSidebarProviderLocalizedText(
                key: "sidebar.provider.extensions.subtitle",
                defaultValue: selectedName == nil
                    ? String(localized: "sidebar.provider.extensions.subtitle", defaultValue: "Custom sidebar")
                    : String(localized: "sidebar.provider.extensions.selectedSubtitle", defaultValue: "Sidebar extension")
            ),
            systemImageName: "puzzlepiece.extension",
            isHostProvided: true
        )
    }

    static func descriptor(for providerId: String) -> CmuxSidebarProviderDescriptor {
        descriptors.first { $0.id == providerId } ?? .defaultWorkspaces
    }

    static func provider(for providerId: String) -> (any CmuxSidebarProvider)? {
        providers.first { $0.descriptor.id == providerId }
    }

    /// Resolves the persisted provider selection to the provider that is
    /// actually rendered. The hosted-extensions provider is part of the
    /// experimental Extensions feature, so a persisted hosted selection falls
    /// back to the default workspaces sidebar while the beta is disabled,
    /// otherwise turning the feature off would strand the user on an empty
    /// sidebar with no switcher entry to escape it. Built-in views are always
    /// honored, so the switcher and its active-view checkmark keep working
    /// regardless of the beta flag.
    static func effectiveProviderId(_ persistedProviderId: String, extensionsEnabled: Bool) -> String {
        if persistedProviderId == hostedExtensionsProviderId, !extensionsEnabled {
            return defaultProviderId
        }
        return persistedProviderId
    }

    static func localizedTitle(for descriptor: CmuxSidebarProviderDescriptor) -> String {
        localizedText(descriptor.title)
    }

    static func localizedText(_ text: CmuxSidebarProviderLocalizedText) -> String {
        NSLocalizedString(
            text.key,
            tableName: "Localizable",
            bundle: .main,
            value: text.defaultValue,
            comment: ""
        )
    }

    static func setProviderId(_ providerId: String, defaults: UserDefaults = .standard) {
        defaults.set(providerId, forKey: defaultsKey)
    }

    @MainActor
    static func showMenu(anchorView: NSView, event: NSEvent?) {
        // The right-click menu switches between the always-available built-in
        // views (and the hosted extension sidebar when the experimental
        // Extensions beta is enabled, plus any beta custom sidebars), so it is
        // shown regardless of the flag.
        let menu = NSMenu()
        let persistedProviderId = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultProviderId
        let selectedProviderId = descriptor(
            for: effectiveProviderId(persistedProviderId, extensionsEnabled: isEnabled)
        ).id
        for descriptor in descriptors {
            let item = NSMenuItem(
                title: localizedTitle(for: descriptor),
                action: #selector(CmuxExtensionSidebarMenuTarget.selectProvider(_:)),
                keyEquivalent: ""
            )
            item.representedObject = descriptor.id
            item.target = CmuxExtensionSidebarMenuTarget.shared
            item.state = selectedProviderId == descriptor.id ? .on : .off
            item.image = NSImage(systemSymbolName: descriptor.systemImageName, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
    }
}

@MainActor
private final class CmuxExtensionSidebarMenuTarget: NSObject {
    static let shared = CmuxExtensionSidebarMenuTarget()

    @objc func selectProvider(_ sender: NSMenuItem) {
        guard let providerId = sender.representedObject as? String else { return }
        CmuxExtensionSidebarSelection.setProviderId(providerId)
    }
}

@MainActor
final class SidebarTabItemSettingsStore: ObservableObject {
    @Published private(set) var snapshot: SidebarTabItemSettingsSnapshot

    private let defaults: UserDefaults
    private let sidebarFontSizeProvider: () async -> CGFloat
    private var sidebarFontSize: CGFloat
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
