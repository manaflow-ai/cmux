import AppKit
import CmuxAppKitSupportUI
import CmuxCommandPalette
import CmuxCore
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import Bonsplit
import Combine
import CmuxSidebarInterpreterClient
import CmuxTerminal
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettingsUI
import CmuxSidebar
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
            GhosttyConfig.loadForCmux().sidebarFontSize
        }.value
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
        // Read the single beta-features section, not the whole `SettingCatalog`.
        // Constructing the full catalog allocates ~20 sub-sections (including
        // `AutomationCatalogSection`/`SecretFileKey`) just to reach one flag;
        // doing that on the SwiftUI body's hot path turned the sidebar
        // re-render into a CPU catastrophe (issue #5970).
        let key = BetaFeaturesCatalogSection().extensions
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
        // `DisableCustomSidebars` (MDM): interpreted sidebars are user- or
        // agent-authored code that can dispatch `cmux(...)` commands.
        guard !ManagedDevicePolicy().isEnforced(.disableCustomSidebars) else { return false }
        // See ``isEnabled``: read only the beta-features section so a body-path
        // access does not allocate the entire `SettingCatalog` (issue #5970).
        let key = BetaFeaturesCatalogSection().customSidebars
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Directory custom sidebars are authored into.
    static var customSidebarsDirectory: URL {
        #if DEBUG
        if let override = customSidebarsDirectoryOverrideForTesting { return override }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/sidebars", isDirectory: true)
    }

    /// One provider descriptor per `<name>.swift`/`<name>.json` file in the
    /// sidebars directory (`.swift` preferred when both exist), titled by the
    /// file's base name.
    static var customSidebarDescriptors: [CmuxSidebarProviderDescriptor] {
        guard !ManagedDevicePolicy().isEnforced(.disableCustomSidebars) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: customSidebarsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        // Priority when several extensions share a base name: js > swift > json.
        func priority(_ ext: String?) -> Int {
            switch ext {
            case "js": return 3
            case "swift": return 2
            case "json": return 1
            default: return 0
            }
        }
        var extensionByName: [String: String] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard priority(ext) > 0 else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if priority(extensionByName[name]) >= priority(ext) { continue }
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
        customSidebarFileURL(forProviderId: providerId, sidebarsDirectory: customSidebarsDirectory)
    }

    static func customSidebarFileURL(forProviderId providerId: String, sidebarsDirectory: URL) -> URL? {
        guard providerId.hasPrefix(customSidebarProviderPrefix) else { return nil }
        let name = String(providerId.dropFirst(customSidebarProviderPrefix.count))
        guard isValidCustomSidebarFileBaseName(name) else { return nil }
        for ext in ["js", "swift", "json"] {
            let url = sidebarsDirectory.appendingPathComponent("\(name).\(ext)", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func isValidCustomSidebarFileBaseName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name == (name as NSString).lastPathComponent
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

    /// Whether an already-`effectiveProviderId`-resolved selection renders the
    /// built-in default workspaces sidebar. This mirrors
    /// `descriptor(for:).id == defaultWorkspacesID` exactly for an effective id,
    /// but WITHOUT building the full ``descriptors`` list — which constructs a
    /// `SettingCatalog` twice (via ``isEnabled``/``customSidebarsEnabled``) and
    /// enumerates the custom-sidebars directory. Those are far too expensive to
    /// run on every SwiftUI body pass; doing so was the multiplier behind the
    /// ~100% CPU re-render loop in issue #5970. Only cheap static lookups and at
    /// most two `fileExists` probes run here, so it is safe for the body.
    ///
    /// The input must be ``effectiveProviderId``'s output: that already routes a
    /// hosted/custom selection back to the default sidebar while its feature gate
    /// is off, so this only needs to confirm the resolved id maps to a renderable
    /// non-default view.
    static func resolvesToDefaultSidebar(effectiveProviderId id: String) -> Bool {
        if id == defaultProviderId { return true }
        if id == hostedExtensionsProviderId { return false }
        if id.hasPrefix(customSidebarProviderPrefix) {
            // A custom selection survives only while its backing file exists;
            // otherwise the descriptor lookup falls back to the default sidebar.
            return customSidebarFileURL(forProviderId: id) == nil
        }
        // Bundled preset providers are always registered regardless of any beta
        // flag; an unknown/stale id has no provider and falls back to default.
        return provider(for: id) == nil
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

    static func effectiveProviderId(
        _ persistedProviderId: String,
        extensionsEnabled: Bool,
        customSidebarsEnabled: Bool
    ) -> String {
        if persistedProviderId.hasPrefix(customSidebarProviderPrefix), !customSidebarsEnabled {
            return defaultProviderId
        }
        return effectiveProviderId(
            persistedProviderId,
            extensionsEnabled: extensionsEnabled
        )
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
private final class SidebarTabItemSettingsStore: ObservableObject {
    @Published private(set) var snapshot: SidebarTabItemSettingsSnapshot

    private let defaults: UserDefaults
    private let sidebarFontSizeProvider: () async -> CGFloat
    private var sidebarFontSize: CGFloat
    private var sidebarFontSizeLoadTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var sidebarFontSizeObserver: NSObjectProtocol?

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
        defaultsObserver = NotificationCenter.default.addUserDefaultsObserver(object: nil) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        refreshSidebarFontSize()
        sidebarFontSizeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySidebarFontSizeDidChange,
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
        if let sidebarFontSizeObserver {
            NotificationCenter.default.removeObserver(sidebarFontSizeObserver)
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

// `SidebarDragState`, `SidebarWorkspaceDragRegistry`, and the DEBUG-only
// `SidebarDragStateRegistry` now live in the `CmuxSidebar`// package. This app-side convenience keeps the `SidebarDragState()` call site
// unchanged by injecting the process-wide cross-window registry the app owns
// at its composition root (`AppDelegate`).
extension SidebarDragState {
    /// Builds a drag state wired to the app's process-wide cross-window drag
    /// registry. Falls back to a fresh registry only if `AppDelegate.shared` is
    /// not yet available (never the case once a sidebar has mounted).
    convenience init() {
        self.init(
            workspaceDragRegistry: AppDelegate.shared?.sidebarWorkspaceDragRegistry
                ?? SidebarWorkspaceDragRegistry()
        )
    }
}

/// Freezes `showsModifierShortcutHints` for the row whose context menu is open,
/// so pressing/releasing the modifier key while the menu is up does not flip
/// the underlying row's shortcut badges (which would be visible around the
/// open context menu). All other rows transition live.
struct VerticalTabsSidebar: View, Equatable {
    // Equatable gates only parent-driven re-evaluation: closures and
    // Bindings are excluded on purpose (recreated per parent eval but
    // functionally identical), and every data source the body renders from
    // (@EnvironmentObject, @ObservedObject, @Binding, @State) invalidates
    // this view directly, bypassing the gate. See TabItemView for the
    // precedent.
    static func == (lhs: VerticalTabsSidebar, rhs: VerticalTabsSidebar) -> Bool {
        lhs.windowId == rhs.windowId
            && lhs.observedWindowReference.window === rhs.observedWindowReference.window
            && lhs.updateViewModel === rhs.updateViewModel
            && lhs.fileExplorerState === rhs.fileExplorerState
            && lhs.featureFlags === rhs.featureFlags
            && lhs.sidebarUnread === rhs.sidebarUnread
            && lhs.titlebarControlsLayoutModel === rhs.titlebarControlsLayoutModel
            && lhs.isPresented == rhs.isPresented
            && lhs.chromeBackgroundColor.isEqual(rhs.chromeBackgroundColor)
    }

    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    var featureFlags: CmuxFeatureFlags = .shared
    var isPresented: Bool = true
    let sidebarUnread: SidebarUnreadModel
    let titlebarControlsLayoutModel: TitlebarControlsLayoutModel
    let windowId: UUID
    let onSendFeedback: () -> Void
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    let observedWindowReference: WeakWindowReference
    let chromeBackgroundColor: NSColor
    var observedWindow: NSWindow? { observedWindowReference.window }
    @EnvironmentObject var tabManager: TabManager
    // Plain reference by design. Native row and titlebar subscribers own the
    // unread invalidation boundary, so this O(workspaces) root stays inert.
    var notificationStore: TerminalNotificationStore { .shared }
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var sidebarRenderWorkerClient: RenderWorkerClient?
    @State var modifierKeyMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State var pointerInteractionMonitor = SidebarPointerInteractionMonitor()
    @StateObject var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var tabItemSettingsStore = SidebarTabItemSettingsStore(
        initialSidebarFontSize: GhosttyConfig.loadForCmux().sidebarFontSize
    )
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State var dragState = SidebarDragState()
    // Bonsplit tab drags arrive through AppKit pasteboard callbacks, not
    // `SidebarDragState`, so they need a separate transient collection flag.
    @State private var isBonsplitWorkspaceDropTargetCollectionActive = false
    @State private var isWorkspaceReorderDropTargetCollectionActive = false
    // Freezes `showsModifierShortcutHints` for the workspace whose context menu
    // is open. Set on the row's contextMenu.onAppear and cleared on
    // .onDisappear so modifier-key transitions don't flip the badges on the
    // row sitting behind the open menu. See `SidebarShortcutHintFreezePolicy`.
    @State private var frozenShortcutHintsTabId: UUID?
    @State private var frozenShortcutHintsValue: Bool = false
    @State private var pendingSelectedWorkspaceScrollId: UUID?
    @State private var collapsedExtensionSidebarSectionIds: Set<String> = []
    @State private var extensionSidebarWorktreeCreationInFlightSectionIds: Set<String> = []
    // Per-workspace transient checklist UI state (never persisted): which
    // rows show their expanded checklist, and a monotonically bumped token
    // per workspace that arms the row's add-item field after a context-menu
    // or palette "Add Checklist Item…". Held at the container so rows stay
    // behind the snapshot boundary (they receive a Bool/Int + closures).
    @State private var expandedChecklistWorkspaceIds: Set<UUID> = []
    @State private var expandedMetadataWorkspaceIds: Set<UUID> = []
    @State private var expandedMarkdownWorkspaceIds: Set<UUID> = []
    @State private var checklistAddFieldActivationTokens: [UUID: Int] = [:]
    /// AppKit-table tap-to-edit sessions (workspace id → checklist item id).
    /// Container-owned so the row model (and the height cache's prototype
    /// measurement) sees the edit-field swap.
    @State private var editingChecklistItemIds: [UUID: UUID] = [:]
    // Which workspace row's checklist popover is open (at most one across
    // the sidebar). Held at the container so rows stay behind the snapshot
    // boundary.
    @State private var bonsplitWorkspaceDropTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()
    @State private var workspaceReorderDropTargetBridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
    @State private var appKitRowSnapshotCache = SidebarRowSnapshotCache()
    /// Bumped once per interactive-resize end: an apply during the drag
    /// is deferred by the AppKit controller. The bump projects one final
    /// authoritative snapshot after mouse-up so state that changed mid-drag
    /// cannot remain stale until an unrelated sidebar change.
    @State private var appKitPostResizeRefreshToken: UInt64 = 0
    // Bumped when a completed row click parks in the table controller
    // awaiting live actions. The park mutates no other tracked state and
    // this view is Equatable-gated, so without this token nothing would
    // re-evaluate the body, no authoritative apply would re-arm the rows,
    // and the parked click would wait on unrelated invalidation
    // (issue #9690: taps only landed after an app focus cycle).
    @State private var appKitTableApplyRequestToken: UInt64 = 0
    @State private var workspaceScrollContentMinHeight: CGFloat = 0
    @State private var checklistPopoverWorkspaceId: UUID?
    // Pending keyed refresh ids are intentionally non-observed. Workspace
    // publisher bursts cross into SwiftUI once per run-loop batch instead of
    // invalidating the full parent projection once per emitting workspace.
    @State private var workspaceSnapshotRefreshCoalescer = SidebarWorkspaceSnapshotRefreshCoalescer()
    // Parent-owned immutable workspace projections. Workspace publishers and
    // async observation streams terminate here, above the LazyVStack; rows
    // receive only values and action closures. This is the ownership boundary
    // that prevents layout/realization from publishing row state (#6707).
    @State private var workspaceSnapshotsById: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
    @State private var extensionSidebarUpdateToken: UInt64 = 0
    // Stable, memoized merged observation publishers for the extension
    // sidebar's `.onReceive` handlers. Rebuilding them inline each body pass
    // re-subscribed `.onReceive` to a fresh publisher every render, replaying
    // the current value and re-bumping `extensionSidebarUpdateToken` in a
    // ~100% CPU loop (issue #5970).
    @State private var extensionSidebarObservationWorkspaceIds: [UUID] = []
    @State private var extensionSidebarObservationPublishersBuilt = false
    @State private var extensionSidebarImmediateObservationPublisher: AnyPublisher<Void, Never> =
        Empty<Void, Never>().eraseToAnyPublisher()
    @State private var extensionSidebarDebouncedObservationPublisher: AnyPublisher<Void, Never> =
        Empty<Void, Never>().eraseToAnyPublisher()
    /// Bumped whenever any workspace's currentDirectory changes; the group
    /// header's resolved cwd-based config (color/icon/context menu /
    /// newWorkspacePlacement) reads it through the body, so a state
    /// invalidation here forces SwiftUI to re-call
    /// `cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd:)`. The anchor
    /// has no TabItemView, so no implicit per-row publisher subscription
    /// would otherwise fire on `cd` while it's not selected.
    @State private var anchorCwdRevision: Int = 0
    @AppStorage(CmuxExtensionSidebarSelection.defaultsKey)
    private var selectedExtensionSidebarProviderId = CmuxExtensionSidebarSelection.defaultProviderId
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled
    @LiveSetting(\.betaFeatures.customSidebars) private var customSidebarsExperimentalEnabled
    @LiveSetting(\.customSidebars.renderer) private var customSidebarRenderer
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
#if DEBUG
    @Environment(\.minimalModeInvalidationProbe) private var minimalModeInvalidationProbe
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif
    @Environment(\.colorScheme) private var sidebarColorScheme
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var sidebarGlobalFontMagnificationPercent

    // The provider to actually render. Built-in views are always honored; only
    // the hosted-extension selection falls back to the default workspaces
    // sidebar while the experimental Extensions feature is disabled, since
    // turning extensions off hides that entry and would otherwise strand the
    // user with no way back. Deriving the effective provider (rather than
    // mutating the persisted selection via an observer) routes correctly on the
    // first render pass and restores the user's choice if extensions are
    // re-enabled. Reading `extensionsExperimentalEnabled` here keeps the view
    // reactive to the flag toggling.
    private var effectiveExtensionSidebarProviderId: String {
        let selected = selectedExtensionSidebarProviderId
        // Touch the @LiveSetting so toggling the flag in Settings still
        // re-renders, but decide with the synchronous UserDefaults read:
        // on a sidebar remount @LiveSetting's initial value lags one tick,
        // which would otherwise flash the default sidebar for a frame
        // before swapping to the custom one.
        _ = customSidebarsExperimentalEnabled
        return CmuxExtensionSidebarSelection.effectiveProviderId(
            selected,
            extensionsEnabled: extensionsExperimentalEnabled,
            customSidebarsEnabled: CmuxExtensionSidebarSelection.customSidebarsEnabled
        )
    }

    /// Live, read-only projection of workspace state handed to custom
    /// sidebars so interpreted Swift can bind to it (e.g.
    /// `ForEach(workspaces) { w in Text(w.title) }`) and re-render when it
    /// changes. A value snapshot built fresh each render, never the store
    /// itself, so it respects the sidebar snapshot-boundary rule.
    private func customSidebarDataContext(
        now: Date,
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> [String: SwiftValue] {
        let selectedId = tabManager.selectedTabId
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            workspace.customSidebarWorkspaceSnapshot(
                index: index,
                selectedId: selectedId,
                unreadCount: unreadSnapshot.unreadCount(forWorkspaceId: workspace.id)
            )
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        let groups = tabManager.workspaceGroups.map { group in
            CustomSidebarGroupSnapshot(
                id: group.id,
                name: group.name,
                isCollapsed: group.isCollapsed,
                isPinned: group.isPinned,
                anchorWorkspaceId: group.anchorWorkspaceId,
                customColor: group.customColor,
                iconSymbol: group.iconSymbol
            )
        }
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: workspaces,
            groups: groups,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
            totalUnreadCount: unreadSnapshot.totalUnreadCount,
            now: now
        )
        return CustomSidebarDataContextBuilder().dataContext(for: snapshot)
    }

    @AppStorage("sidebarMatchTerminalBackground")
    private var sidebarMatchTerminalBackground = false
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
    private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
    private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset

    let tabRowSpacing: CGFloat = 2
    private static let extensionSidebarObservationCoalesceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(40)
    private static let extensionSidebarDisclosureAnimation = Animation.easeInOut(duration: 0.18)
    private var sidebarTitlebarInteractionHeight: CGFloat {
        MinimalModeChromeMetrics.titlebarHeight
    }

    /// Adapter binding for extension sidebar drop delegates that still expect
    /// `@Binding<UUID?>`. Reads resolve from the retained native session rather
    /// than a presentation that may have disappeared during reconstruction.
    private var draggedTabIdBinding: Binding<UUID?> {
        Binding(
            // A live coordinator identity is valid for both local reorders and
            // cross-window destination presentations. The registry is the
            // liveness gate; residual pasteboard data never reaches this path.
            get: {
                guard acceptsLiveSidebarPayloadForBinding() else { return nil }
                return dragState.draggedTabId ?? dragState.currentWorkspaceDragId
            },
            set: { newValue in
                if let newValue {
                    _ = dragState.activateDragging(tabId: newValue)
                } else {
                    // A destination may tear down its SwiftUI presentation as
                    // soon as it accepts a drop. That is not native source
                    // completion: retain the coordinator session until AppKit
                    // calls the source/controller's terminal callback.
                    dragState.dismissPresentation()
                }
            }
        )
    }

    /// Keeps extension-sidebar delegates from falling back to a newer process
    /// session when a late payload from an older drag is still being delivered.
    private func acceptsLiveSidebarPayloadForBinding() -> Bool {
        dragState.acceptsLiveSidebarSessionForCurrentPasteboard()
    }

    /// Adapter binding mirroring `draggedTabIdBinding`. See its doc comment.
    private var dropIndicatorBinding: Binding<SidebarDropIndicator?> {
        Binding(
            get: { dragState.dropIndicator },
            set: { dragState.setDropIndicator($0) }
        )
    }

    /// Computed in the parent so `SidebarEmptyArea` can render its top-edge
    /// indicator from a value snapshot without holding a `SidebarDragState`
    /// reference (snapshot-boundary rule). Delegates to a pure predicate so
    /// the logic is unit-testable in isolation from view state.
    private func emptyAreaTopDropIndicatorVisible() -> Bool {
        let reorderIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            usesTopLevelRows: dragState.dropIndicatorUsesTopLevelRows
        )
        return SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            lastTabId: reorderIds.last,
            indicatorScope: dragState.dropIndicatorScope
        )
    }

    /// Constructs the drop delegate for the empty area in the parent scope,
    /// so the child view receives a closure-bundle-equivalent value rather
    /// than an `@Observable` store.
    private func emptyAreaTabDropDelegate(renderContext: WorkspaceListRenderContext) -> SidebarTabDropDelegate {
        SidebarTabDropDelegate(
            targetTabId: nil,
            tabManager: tabManager,
            workspaceGroupIdByWorkspaceId: renderContext.workspaceGroupIdByWorkspaceId,
            dragState: dragState,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: nil,
            dragAutoScrollController: dragAutoScrollController
        )
    }

    private func sidebarDropIndicatorRowIds(
        draggedWorkspaceId: UUID,
        scope: SidebarWorkspaceReorderDropIndicatorScope,
        tabs: [Workspace],
        workspaceGroups: [WorkspaceGroup],
        visibleWorkspaceRowIds: [UUID]
    ) -> [UUID] {
        switch scope {
        case .raw:
            return tabs.map(\.id)
        case .topLevel:
            let topLevelIds = tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedWorkspaceId,
                usesTopLevelRows: true
            )
            let topLevelSet = Set(topLevelIds).union(
                workspaceGroups.filter(\.isEmpty).map(\.anchorWorkspaceId)
            )
            // `sidebarReorderWorkspaceIds` is intentionally backed by live
            // tabs, so header-only groups are absent. Re-project its row space
            // through the visible render snapshot to retain empty headers in
            // the painter's display order without admitting hidden members.
            return visibleWorkspaceRowIds.filter { topLevelSet.contains($0) }
        case .group(let groupId):
            guard workspaceGroups.contains(where: { $0.id == groupId }) else { return [] }
            let visibleIds = Set(visibleWorkspaceRowIds)
            let memberIds = tabs
                .filter { $0.groupId == groupId && visibleIds.contains($0.id) }
                .map(\.id)
            if !memberIds.isEmpty {
                return memberIds
            }
            // Header-only groups have no member tab row. Their stable header
            // identity is still a visible row and must participate in the
            // scoped indicator painter so an accepted adopt drop gets a line.
            return workspaceGroups.first { $0.id == groupId }
                .map { [$0.anchorWorkspaceId] } ?? []
        }
    }

    private var sidebarTopScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.topScrimHeight
    }

    private var sidebarBottomScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.bottomScrimHeight
    }

    private var titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsTopInset,
                range: MinimalModeTitlebarDebugSettings.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
        )
    }

    private var minimalModeSidebarTitlebarControlsTopPadding: CGFloat {
        guard let observedWindow else {
            return MinimalModeSidebarTitlebarControlsMetrics.topInset
        }
        return minimalModeSidebarTitlebarControlsTopInset(in: observedWindow)
    }

    private var showsSidebarNotificationMessage: Bool {
        tabItemSettingsStore.snapshot.showsNotificationMessage
    }

    private var workspaceNumberShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
    }

    private func minimalModeSidebarTitlebarControlsOverlay() -> some View {
        MinimalModeSidebarTitlebarControlsOverlay(
            unreadModel: sidebarUnread,
            layoutModel: titlebarControlsLayoutModel,
            leadingInset: CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset),
            topPadding: minimalModeSidebarTitlebarControlsTopPadding,
            onToggleSidebar: onToggleSidebar,
            onToggleNotifications: { anchorView in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: anchorView
                )
            },
            onNewTab: onNewTab,
            onFocusHistoryBack: {
                if !tabManager.navigateBack() {
                    NSSound.beep()
                }
            },
            onFocusHistoryForward: {
                if !tabManager.navigateForward() {
                    NSSound.beep()
                }
            }
        )
    }

    struct WorkspaceListRenderContext {
        let environment: SidebarWorkspaceTableEnvironmentSnapshot
        let tabs: [Workspace]
        /// Stored `tabs.map(\.id)` snapshot so row predicates avoid O(n) work.
        let tabIds: [UUID]
        /// Drag-scope row ids shared by every visible row for this render pass.
        let sidebarReorderIds: [UUID]
        let workspaceCount: Int
        let canCloseWorkspace: Bool
        let workspaceNumberShortcut: StoredShortcut
        let tabItemSettings: SidebarTabItemSettingsSnapshot
        let showsAgentActivity: Bool
        let pinResolutionContext: WorkspaceActionDispatcher.PinResolutionContext
        let tabIndexById: [UUID: Int]
        let numberedWorkspaceIndexById: [UUID: Int]
        let workspaceById: [UUID: Workspace]
        let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
        let selectedContextTargetIds: [UUID]
        let selectedRemoteContextMenuWorkspaceIds: [UUID]
        let allSelectedRemoteContextMenuTargetsConnecting: Bool
        let allSelectedRemoteContextMenuTargetsDisconnected: Bool
        let workspaceGroups: [WorkspaceGroup]
        let workspaceGroupById: [UUID: WorkspaceGroup]
        let memberWorkspaceIdsByGroupId: [UUID: [UUID]]
        let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
        let workspaceRenderItems: [SidebarWorkspaceRenderItem]
        let visibleWorkspaceRowIds: [UUID]

        var workspaceIds: [UUID] { tabIds }
    }

    private func activateSidebarInteractions() {
        if !pointerInteractionMonitor.isActive {
            pointerInteractionMonitor.start(onMiddleClickWorkspace: { workspaceId in
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
#if DEBUG
                cmuxDebugLog("sidebar.close workspace=\(workspaceId.uuidString.prefix(5)) method=middleClick")
#endif
                tabManager.closeWorkspaceWithConfirmation(workspace)
            }, onBeginWorkspaceDrag: { dragId, sourceView, event, draggingFrame, dragImage in
                let workspaceId: UUID
                if tabManager.tabs.contains(where: { $0.id == dragId }) {
                    workspaceId = dragId
                } else if let group = tabManager.workspaceGroups.first(where: { $0.id == dragId }) {
                    if group.isEmpty {
                        workspaceId = group.id
                    } else {
                        guard let liveAnchorId = tabManager.workspaceGroupAnchor(for: group.id)?.id else {
                            return false
                        }
                        workspaceId = liveAnchorId
                    }
                } else {
                    return false
                }
#if DEBUG
                cmuxDebugLog("sidebar.nativeDrag tab=\(workspaceId.uuidString.prefix(5))")
#endif
                return dragState.beginNativeDragging(
                    tabId: workspaceId,
                    pasteboardItem: SidebarTabDragPayload(tabId: workspaceId).pasteboardItem(),
                    sourceView: sourceView,
                    event: event,
                    draggingFrame: draggingFrame,
                    dragImage: dragImage
                )
            })
        }
        if showModifierHoldHints {
            modifierKeyMonitor.setHostWindow(observedWindow)
            modifierKeyMonitor.start()
        } else {
            modifierKeyMonitor.stop()
        }
        dragState.dismissPresentation()
        isBonsplitWorkspaceDropTargetCollectionActive = false
        isWorkspaceReorderDropTargetCollectionActive = false
        #if DEBUG
        AppDelegate.shared?.sidebarDragStateRegistry.register(windowId: windowId, dragState: dragState)
        #endif
    }

    private func deactivateSidebarInteractions() {
        appKitRowSnapshotCache.prune(keeping: [])
        if !workspaceSnapshotsById.isEmpty { workspaceSnapshotsById = [:] }
        if pointerInteractionMonitor.isActive {
            pointerInteractionMonitor.stop()
        }
        modifierKeyMonitor.stop()
        dragAutoScrollController.stop()
        // Sidebar/window reconstruction is not evidence that AppKit's native
        // source ended. Keep the coordinator session alive and dismiss only
        // this presentation; its source callback performs terminal cleanup.
        dragState.dismissPresentation()
        isBonsplitWorkspaceDropTargetCollectionActive = false
        isWorkspaceReorderDropTargetCollectionActive = false
        #if DEBUG
        AppDelegate.shared?.sidebarDragStateRegistry.unregister(windowId: windowId)
        #endif
    }

    var body: some View {
#if DEBUG
        let _ = { minimalModeInvalidationProbe.verticalTabsSidebarBody?() }()
#endif
        let signpost = SidebarProfilingSignposts.begin("vertical-sidebar-body", "workspaces=\(tabManager.tabs.count) selected=\(sidebarShortTabId(tabManager.selectedTabId))")
        // Retain the native table identity while hidden without continuing the
        // O(workspaces) projection pipeline. Reveal rebuilds one authoritative
        // snapshot from the current model before the controller applies again.
        let tabs = isPresented ? tabManager.tabs : []
        let workspaceCount = tabs.count
        let canCloseWorkspace = workspaceCount > 1
        let workspaceNumberShortcut = self.workspaceNumberShortcut
        let tabItemSettings = tabItemSettingsStore.snapshot
        let tabIds = tabs.map(\.id)
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let workspaceById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let pinResolutionContext = WorkspaceActionDispatcher.PinResolutionContext(
            workspacesById: workspaceById,
            liveWorkspaceIds: Set(tabIds)
        )
        let orderedSelectedTabs = tabs.filter { selectedTabIds.contains($0.id) }
        let selectedContextTargetIds = orderedSelectedTabs.map(\.id)
        let selectedRemoteContextMenuTargets = orderedSelectedTabs.filter {
            $0.isRemoteWorkspace && !$0.isManagedCloudVMWorkspace
        }
        let selectedRemoteContextMenuWorkspaceIds = selectedRemoteContextMenuTargets.map(\.id)
        let allSelectedRemoteContextMenuTargetsConnecting = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy {
                $0.remoteConnectionState == .connecting || $0.remoteConnectionState == .reconnecting
            }
        let allSelectedRemoteContextMenuTargetsDisconnected = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .disconnected }
        let workspaceGroups = isPresented ? tabManager.workspaceGroups : []
        let workspaceGroupById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let workspaceGroupIdByWorkspaceId = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(
            tabs: tabs,
            groupsById: workspaceGroupById
        )
        let memberWorkspaceIdsByGroupId = SidebarWorkspaceRenderItem.memberWorkspaceIdsByGroupId(
            tabs: tabs,
            groupsById: workspaceGroupById,
            effectiveMembership: workspaceGroupIdByWorkspaceId
        )
        let workspaceGroupMenuSnapshot = WorkspaceGroupMenuSnapshot(
            items: workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        )
        let workspaceRenderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: workspaceGroupById,
            orderedGroups: workspaceGroups,
            effectiveMembership: workspaceGroupIdByWorkspaceId
        )
        let numberedWorkspaceIndexById = SidebarWorkspaceRenderItem.numberedWorkspaceIndexById(
            from: workspaceRenderItems
        )
        let visibleWorkspaceRowIds = workspaceRenderItems.map(\.rowWorkspaceId)
        let draggedSidebarTabId = dragState.draggedTabId
        let dropIndicatorScope = dragState.dropIndicatorScope
        let sidebarReorderIds = draggedSidebarTabId.map {
            sidebarDropIndicatorRowIds(
                draggedWorkspaceId: $0,
                scope: dropIndicatorScope,
                tabs: tabs,
                workspaceGroups: workspaceGroups,
                visibleWorkspaceRowIds: visibleWorkspaceRowIds
            )
        } ?? []
#if DEBUG
        let tableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: sidebarColorScheme,
            globalFontMagnificationPercent: sidebarGlobalFontMagnificationPercent,
            lazyContractProbe: sidebarLazyContractProbe
        )
#else
        let tableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: sidebarColorScheme,
            globalFontMagnificationPercent: sidebarGlobalFontMagnificationPercent
        )
#endif
        let renderContext = WorkspaceListRenderContext(
            environment: tableEnvironment,
            tabs: tabs,
            tabIds: tabIds,
            sidebarReorderIds: sidebarReorderIds,
            workspaceCount: workspaceCount,
            canCloseWorkspace: canCloseWorkspace,
            workspaceNumberShortcut: workspaceNumberShortcut,
            tabItemSettings: tabItemSettings,
            showsAgentActivity: tabItemSettings.details.showAgentActivity
                && CmuxFeatureFlags.shared.isSidebarWorkspaceAgentSpinnerEnabled,
            pinResolutionContext: pinResolutionContext,
            tabIndexById: tabIndexById,
            numberedWorkspaceIndexById: numberedWorkspaceIndexById,
            workspaceById: workspaceById,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId,
            selectedContextTargetIds: selectedContextTargetIds,
            selectedRemoteContextMenuWorkspaceIds: selectedRemoteContextMenuWorkspaceIds,
            allSelectedRemoteContextMenuTargetsConnecting: allSelectedRemoteContextMenuTargetsConnecting,
            allSelectedRemoteContextMenuTargetsDisconnected: allSelectedRemoteContextMenuTargetsDisconnected,
            workspaceGroups: workspaceGroups,
            workspaceGroupById: workspaceGroupById,
            memberWorkspaceIdsByGroupId: memberWorkspaceIdsByGroupId,
            workspaceGroupMenuSnapshot: workspaceGroupMenuSnapshot,
            workspaceRenderItems: workspaceRenderItems,
            visibleWorkspaceRowIds: visibleWorkspaceRowIds
        )
        let _ = SidebarProfilingSignposts.end(signpost)
        ZStack(alignment: .bottomLeading) {
            if CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: effectiveExtensionSidebarProviderId) {
                workspaceScrollArea(renderContext: renderContext)
            } else {
                extensionSidebarScrollArea(renderContext: renderContext)
            }
            if isPresented {
                SidebarFooter(
                    updateViewModel: updateViewModel,
                    fileExplorerState: fileExplorerState,
                    modifierKeyMonitor: modifierKeyMonitor,
                    onSendFeedback: onSendFeedback
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("Sidebar")
        .ignoresSafeArea()
        .overlay(alignment: .trailing) {
            WindowChromeBorder(
                orientation: .vertical,
                backgroundColor: chromeBackgroundColor
            )
        }
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                modifierKeyMonitor.setHostWindow(showModifierHoldHints ? window : nil)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            if isPresented { activateSidebarInteractions() }
        }
        .onDisappear {
            deactivateSidebarInteractions()
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                activateSidebarInteractions()
            } else {
                deactivateSidebarInteractions()
            }
        }
        .onChange(of: showModifierHoldHints) { _, enabled in
            guard isPresented else {
                modifierKeyMonitor.stop()
                return
            }
            if enabled {
                modifierKeyMonitor.setHostWindow(observedWindow)
                modifierKeyMonitor.start()
            } else {
                modifierKeyMonitor.stop()
                frozenShortcutHintsTabId = nil
                frozenShortcutHintsValue = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceChecklistAddItemRequested)) { notification in
            guard isPresented else { return }
            guard let workspaceId = notification.userInfo?[WorkspaceTodoActions.workspaceIdUserInfoKey] as? UUID,
                  tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return }
            if WorkspaceTodoFeature.checklistStyle == .popover {
                checklistPopoverWorkspaceId = workspaceId
            } else {
                expandedChecklistWorkspaceIds.insert(workspaceId)
            }
            checklistAddFieldActivationTokens[workspaceId, default: 0] += 1
        }
        .onChange(of: dragState.draggedTabId) { newDraggedTabId in
#if DEBUG
            cmuxDebugLog("sidebar.dragState.sidebar tab=\(sidebarShortTabId(newDraggedTabId))")
#endif
            guard newDraggedTabId == nil else { return }
            dragAutoScrollController.stop()
            dragState.clearDropIndicator()
        }
        .onChange(of: tabIds) { tabIds in
            guard let frozenTabId = frozenShortcutHintsTabId,
                  !tabIds.contains(frozenTabId) else { return }
            frozenShortcutHintsTabId = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workspaceScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        // The AppKit NSTableView sidebar is opt-in while it soaks; default stays
        // on the SwiftUI list. The flag key is declared only in FeatureFlags.swift.
        Group {
            if featureFlags.isAppKitSidebarListEnabled {
                AnyView(
                    appKitWorkspaceScrollArea(renderContext: renderContext)
                        // Push the flag value into the portal from its single
                        // evaluation site (feature-flag lint one-file rule).
                        .onAppear { WindowTerminalPortal.usesCoalescedAnchorFailsafe = true }
                )
            } else {
                AnyView(
                    SidebarUnreadSnapshotReader(source: sidebarUnread) { unreadSnapshot in
                        legacyWorkspaceScrollArea(
                            renderContext: renderContext,
                            unreadSnapshot: unreadSnapshot
                        )
                    }
                    .onAppear { WindowTerminalPortal.usesCoalescedAnchorFailsafe = false }
                )
            }
        }
        // Workspace publisher observations and the snapshot refresh feed BOTH
        // list implementations, so they live on the shared parent. They
        // previously hung off the legacy subtree only, which the AppKit flag
        // unmounts — leaving workspaceSnapshotsById permanently empty, so
        // renames, colors, pins, and descriptions never invalidated the
        // sidebar and only painted when an unrelated change rebuilt the rows.
        .sidebarProcessTitleObservations(
            ids: renderContext.workspaceIds,
            models: renderContext.tabs.map(\.sidebarProcessTitleObservation)
        ) { workspaceId in
            guard isPresented else { return }
            scheduleWorkspaceSnapshotRefresh(workspaceId: workspaceId)
        }
        .sidebarAgentRuntimeObservations(
            ids: renderContext.workspaceIds,
            models: renderContext.tabs.map(\.sidebarAgentRuntimeObservation)
        ) { workspaceId in
            guard isPresented else { return }
            scheduleWorkspaceSnapshotRefresh(workspaceId: workspaceId)
        }
        .sidebarWorkspaceObservations(
            ids: renderContext.workspaceIds,
            workspaces: renderContext.tabs,
            debouncedInterval: Self.extensionSidebarObservationCoalesceInterval
        ) { workspaceId in
            guard isPresented else { return }
            scheduleWorkspaceSnapshotRefresh(workspaceId: workspaceId)
        }
        .onAppear {
            if isPresented, !featureFlags.isAppKitSidebarListEnabled {
                refreshWorkspaceSnapshots()
            }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                workspaceSnapshotRefreshCoalescer.cancel()
            } else if !featureFlags.isAppKitSidebarListEnabled {
                refreshWorkspaceSnapshots()
            }
        }
        .onChange(of: renderContext.workspaceIds) { _, _ in
            if isPresented, !featureFlags.isAppKitSidebarListEnabled {
                refreshWorkspaceSnapshots()
            }
        }
        .onChange(of: renderContext.tabItemSettings) { _, _ in
            if isPresented, !featureFlags.isAppKitSidebarListEnabled {
                refreshWorkspaceSnapshots()
            }
        }
        .onChange(of: renderContext.showsAgentActivity) { _, _ in
            if isPresented, !featureFlags.isAppKitSidebarListEnabled {
                refreshWorkspaceSnapshots()
            }
        }
        .onDisappear {
            workspaceSnapshotRefreshCoalescer.cancel()
        }
    }

    private func legacyWorkspaceScrollArea(
        renderContext: WorkspaceListRenderContext,
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> some View {
        let scrollInsets = SidebarWorkspaceScrollInsets.workspaceList
        return GeometryReader { viewport in
            // Keep viewport geometry as a downward-only layout input. Writing
            // this value into @State from onGeometryChange feeds an
            // NSHostingView layout pass back into the same LazyVStack graph;
            // scrolling plus row-height churn can then prevent convergence.
            let contentMinHeight = SidebarWorkspaceScrollLayout.contentMinHeight(
                viewportHeight: viewport.size.height,
                insets: scrollInsets
            )
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    workspaceScrollContent(
                        renderContext: renderContext,
                        minHeight: contentMinHeight,
                        unreadSnapshot: unreadSnapshot
                    )
                }
            .coordinateSpace(name: SidebarPointerInteractionMonitor.coordinateSpaceName)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sidebarPointerEventHost(pointerInteractionMonitor)
            .background(
                SidebarScrollViewResolver { scrollView in
                    configureSidebarScrollView(scrollView)
                    dragAutoScrollController.attach(scrollView: scrollView)
                }
                .frame(width: 0, height: 0)
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: scrollInsets.top).allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: scrollInsets.bottom).allowsHitTesting(false)
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
            .overlay(alignment: .top) {
                // The sidebar top strip remains draggable and handles
                // double-clicks with the standard titlebar action.
                WindowDragHandleView()
                    .frame(height: sidebarTitlebarInteractionHeight)
                    .background(TitlebarDoubleClickMonitorView())
            }
            .overlay(alignment: .topLeading) {
                minimalModeSidebarTitlebarControlsOverlay()
            }
            .overlay(alignment: .top) {
                workspaceReorderDropOverlay(
                    renderContext: renderContext,
                    pointOffset: CGSize(width: 0, height: -scrollInsets.top)
                )
                .frame(maxWidth: .infinity)
                .frame(height: scrollInsets.top)
            }
            .background(Color.clear)
            .modifier(ClearScrollBackground())
            .onAppear {
                requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
            }
            .onChange(of: tabManager.selectedTabId) { _, _ in
                requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                // Workspace switches produce no outside click for .transient auto-dismiss; close popovers explicitly.
                if let dismissed = checklistPopoverWorkspaceId { checklistAddFieldActivationTokens[dismissed] = nil }
                checklistPopoverWorkspaceId = nil
            }
            .onChange(of: renderContext.workspaceIds) { oldWorkspaceIds, newWorkspaceIds in
                guard shouldRequestSelectedWorkspaceScrollAfterWorkspaceIdsChange(
                    from: oldWorkspaceIds,
                    to: newWorkspaceIds
                ) else {
                    flushPendingSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                    return
                }
                requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceOrderDidChange)) { notification in
                requestSelectedWorkspaceScrollAfterWorkspaceOrderChange(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceCurrentDirectoryDidChange)) { _ in
                // Drive a revision counter that the group-header resolver
                // reads. Forces SwiftUI to re-invoke `cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd:)`
                // when the anchor's cwd changes while the anchor is not
                // the selected workspace — otherwise group color/icon/menu
                // and `+` placement reflect the previous cwd until some
                // unrelated sidebar event fires.
                anchorCwdRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: SidebarMultiSelectionDidHideEvent.notificationName)) { notification in
                // Group collapse hides some workspaces without changing
                // focus or wiping the rest of the multi-selection. Strip
                // only the hidden ids; if focus moved, make sure the new
                // focused id is still represented.
                guard let model = notification.object as? SidebarMultiSelectionModel,
                      model === tabManager.sidebarMultiSelection,
                      let event = SidebarMultiSelectionDidHideEvent(notification) else { return }
                var next = selectedTabIds.subtracting(event.hiddenWorkspaceIds)
                if let movedFocus = event.focusedWorkspaceId {
                    next.insert(movedFocus)
                    if let index = tabManager.tabs.firstIndex(where: { $0.id == movedFocus }) {
                        lastSidebarSelectionIndex = index
                    }
                }
                if next != selectedTabIds {
                    selectedTabIds = next
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: SidebarMultiSelectionShouldCollapseEvent.notificationName)) { notification in
                // Keyboard nav (selectNextTab/selectPreviousTab) posts
                // this so any stale Shift-click range in the sidebar's
                // SwiftUI selectedTabIds collapses to just the newly-
                // focused workspace. Without this, batch context-menu /
                // shortcut actions would still target the stale range.
                guard let model = notification.object as? SidebarMultiSelectionModel,
                      model === tabManager.sidebarMultiSelection,
                      let event = SidebarMultiSelectionShouldCollapseEvent(notification) else { return }
                let focusedId = event.focusedWorkspaceId
                let next: Set<UUID> = tabManager.tabs.contains(where: { $0.id == focusedId }) ? [focusedId] : []
                if selectedTabIds != next {
                    selectedTabIds = next
                }
                if let index = tabManager.tabs.firstIndex(where: { $0.id == focusedId }) {
                    lastSidebarSelectionIndex = index
                }
            }
        }
        }
    }

    private func requestSelectedWorkspaceScroll(
        _ proxy: ScrollViewProxy,
        renderContext: WorkspaceListRenderContext
    ) {
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              renderContext.workspaceIds.contains(selectedWorkspaceId) else {
            pendingSelectedWorkspaceScrollId = nil
            return
        }

        pendingSelectedWorkspaceScrollId = selectedWorkspaceId
        flushPendingSelectedWorkspaceScroll(proxy, renderContext: renderContext)
    }

        private func flushPendingSelectedWorkspaceScroll(
        _ proxy: ScrollViewProxy,
        renderContext: WorkspaceListRenderContext
    ) {
        guard let selectedWorkspaceId = pendingSelectedWorkspaceScrollId else { return }

        // Scroll unconditionally: ScrollViewProxy resolves `.id(_:)` values in
        // lazy containers without requiring the row to be realized, and an
        // unknown id is a harmless no-op. The previous design gated this on a
        // per-row "laid-out row ids" PreferenceKey whose sidebar-wide reduce
        // fed `@State` writes from inside the layout/preference update cycle,
        // the cmux-owned edge in the sidebar layout livelock
        // (https://github.com/manaflow-ai/cmux/issues/2586). No anchor means
        // SwiftUI scrolls the minimum needed to reveal the row.
        let group = renderContext.workspaceById[selectedWorkspaceId]?.groupId
            .flatMap { renderContext.workspaceGroupById[$0] }
        proxy.scrollTo(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: selectedWorkspaceId,
            group: group
        ))
        pendingSelectedWorkspaceScrollId = nil
    }

        private func shouldRequestSelectedWorkspaceScrollAfterWorkspaceIdsChange(
        from oldWorkspaceIds: [UUID],
        to newWorkspaceIds: [UUID]
    ) -> Bool {
        SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: tabManager.selectedTabId,
            oldWorkspaceIds: oldWorkspaceIds,
            newWorkspaceIds: newWorkspaceIds
        )
    }

        private func requestSelectedWorkspaceScrollAfterWorkspaceOrderChange(_ notification: Notification) {
        guard let manager = notification.object as? TabManager, manager === tabManager else {
            return
        }
        guard let selectedWorkspaceId = tabManager.selectedTabId else { return }
        let movedWorkspaceIds = notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
        guard movedWorkspaceIds.contains(selectedWorkspaceId) else { return }
        pendingSelectedWorkspaceScrollId = selectedWorkspaceId
    }

    private func appKitWorkspaceScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        let _ = anchorCwdRevision
        let _ = appKitPostResizeRefreshToken
        let _ = appKitTableApplyRequestToken
        let contentUpdate: SidebarWorkspaceTableView.ContentUpdate
        let isDividerDragActive = isPresented
            && TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: observedWindow)
        if !isPresented || isDividerDragActive {
            // The AppKit controller remains the authoritative owner of its
            // applied rows. A payload-free update avoids constructing transient
            // row/action closure graphs while SwiftUI repeatedly lays out.
            contentUpdate = .preserveAppliedRows
        } else {
            contentUpdate = .apply(
                rows: appKitWorkspaceTableRows(renderContext: renderContext),
                actions: workspaceTableActions(renderContext: renderContext)
            )
            appKitRowSnapshotCache.prune(keeping: Set(renderContext.workspaceIds))
        }
        let selectedWorkspaceId = isPresented ? tabManager.selectedTabId : nil
        let selectedScrollTargetWorkspaceId: UUID? = selectedWorkspaceId.map { selectedId in
            let group = renderContext.workspaceById[selectedId]?.groupId
                .flatMap { renderContext.workspaceGroupById[$0] }
            return SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
                selectedWorkspaceId: selectedId,
                group: group
            )
        }
        // A group header is keyed by its stable group id, not by the mutable
        // anchor workspace id. Keep the full live row identity set available
        // while hidden so anchor promotion cannot prune a retained header.
        let liveRowIds: [SidebarWorkspaceRenderItemID] = isPresented
            ? renderContext.workspaceRenderItems.map(\.id)
            : tabManager.workspaceGroups.map { .group($0.id) }
                + tabManager.tabs.map { .workspace($0.id) }
        return SidebarWorkspaceTableView(
            contentUpdate: contentUpdate,
            workspaceIds: isPresented ? renderContext.workspaceIds : tabManager.tabs.map(\.id),
            liveRowIds: liveRowIds,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId,
            isPresented: isPresented,
            unreadSource: sidebarUnread,
            onDeferredClickAwaitingApply: { appKitTableApplyRequestToken &+= 1 }
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
            .overlay(alignment: .top) {
                if isPresented {
                    // The sidebar top strip remains draggable and handles
                    // double-clicks with the standard titlebar action.
                    WindowDragHandleView()
                        .frame(height: sidebarTitlebarInteractionHeight)
                        .background(TitlebarDoubleClickMonitorView())
                }
            }
            .overlay(alignment: .topLeading) {
                if isPresented { minimalModeSidebarTitlebarControlsOverlay() }
            }
            .background(Color.clear)
            .onChange(of: selectedWorkspaceId) { _, _ in
                guard isPresented, let dismissed = checklistPopoverWorkspaceId else { return }
                // Workspace switches produce no outside click for .transient auto-dismiss; close popovers explicitly.
                checklistAddFieldActivationTokens[dismissed] = nil
                checklistPopoverWorkspaceId = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .cmuxInteractiveGeometryResizeDidEnd)) { _ in
                guard isPresented else { return }
                // The controller reconciles its latest deferred input. Project
                // once more from live state so a change arriving at drag-end
                // cannot wait for an unrelated invalidation.
                appKitPostResizeRefreshToken &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceCurrentDirectoryDidChange)) { _ in
                guard isPresented else { return }
                // Drive a revision counter that the group-header resolver
                // reads. Forces SwiftUI to re-invoke `cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd:)`
                // when the anchor's cwd changes while the anchor is not
                // the selected workspace — otherwise group color/icon/menu
                // and `+` placement reflect the previous cwd until some
                // unrelated sidebar event fires.
                anchorCwdRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: SidebarMultiSelectionDidHideEvent.notificationName)) { notification in
                guard isPresented else { return }
                // Group collapse hides some workspaces without changing
                // focus or wiping the rest of the multi-selection. Strip
                // only the hidden ids; if focus moved, make sure the new
                // focused id is still represented.
                guard let model = notification.object as? SidebarMultiSelectionModel,
                      model === tabManager.sidebarMultiSelection,
                      let event = SidebarMultiSelectionDidHideEvent(notification) else { return }
                var next = selectedTabIds.subtracting(event.hiddenWorkspaceIds)
                if let movedFocus = event.focusedWorkspaceId {
                    next.insert(movedFocus)
                    if let index = tabManager.tabs.firstIndex(where: { $0.id == movedFocus }) {
                        lastSidebarSelectionIndex = index
                    }
                }
                if next != selectedTabIds {
                    selectedTabIds = next
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: SidebarMultiSelectionShouldCollapseEvent.notificationName)) { notification in
                guard isPresented else { return }
                // Keyboard nav (selectNextTab/selectPreviousTab) posts
                // this so any stale Shift-click range in the sidebar's
                // SwiftUI selectedTabIds collapses to just the newly-
                // focused workspace. Without this, batch context-menu /
                // shortcut actions would still target the stale range.
                guard let model = notification.object as? SidebarMultiSelectionModel,
                      model === tabManager.sidebarMultiSelection,
                      let event = SidebarMultiSelectionShouldCollapseEvent(notification) else { return }
                let focusedId = event.focusedWorkspaceId
                let next: Set<UUID> = tabManager.tabs.contains(where: { $0.id == focusedId }) ? [focusedId] : []
                if selectedTabIds != next {
                    selectedTabIds = next
                }
                if let index = tabManager.tabs.firstIndex(where: { $0.id == focusedId }) {
                    lastSidebarSelectionIndex = index
                }
            }
    }

    private func appKitWorkspaceTableRows(
        renderContext: WorkspaceListRenderContext
    ) -> [SidebarWorkspaceTableRowConfiguration] {
        appKitRowSnapshotCache.resetIfSettingsChanged(renderContext.tabItemSettings)
#if DEBUG
        // One line per full row-projection rebuild: the countable signal for
        // whether a change class re-renders the sidebar subtree or skips it.
        cmuxDebugLog("sidebar.table.rowsBuild items=\(renderContext.workspaceRenderItems.count)")
#endif
        // AppKit applies the live unread snapshot inside its controller. Keep
        // root row construction independent from notification publications.
        let unreadSnapshot = SidebarUnreadSnapshot()
        let unreadSummariesByWorkspaceId = unreadSnapshot.summaryByWorkspaceId
        let notificationIndex = SidebarWorkspaceNotificationIndex(
            notifications: notificationStore.notifications
        )
        let workspaceRowInputsById = Dictionary(uniqueKeysWithValues: renderContext.tabs.map { workspace in
            (
                workspace.id,
                workspaceRowInput(
                    workspace,
                    renderContext: renderContext,
                    unreadSummariesByWorkspaceId: unreadSummariesByWorkspaceId
                )
            )
        })
        let groupRowSnapshotsById = Dictionary(uniqueKeysWithValues: renderContext.workspaceGroups.map { group in
            (
                group.id,
                sidebarWorkspaceGroupRowSnapshot(
                    group: group,
                    memberWorkspaceIds: renderContext.memberWorkspaceIdsByGroupId[group.id] ?? [],
                    renderContext: renderContext,
                    unreadSnapshot: unreadSnapshot,
                    notificationIndex: notificationIndex,
                    shouldCollectWorkspaceDropTargets: false
                )
            )
        })
        let listSnapshot = SidebarWorkspaceRowsSnapshot(
            workspaceRowsById: workspaceRowInputsById,
            groupRowsById: groupRowSnapshotsById,
            selectedContextTargetIds: renderContext.selectedContextTargetIds,
            anchorWorkspaceIds: Set(renderContext.workspaceGroups.compactMap(\.liveAnchorWorkspaceId)),
            workspaceGroupMenuSnapshot: renderContext.workspaceGroupMenuSnapshot,
            canCreateEmptyGroup: tabManager.selectedTab?.isRemoteTmuxMirror != true,
            notificationIndex: notificationIndex
        )
        return renderContext.workspaceRenderItems.compactMap { item -> SidebarWorkspaceTableRowConfiguration? in
            switch item {
            case .groupHeader(let groupId, _):
                guard let group = renderContext.workspaceGroupById[groupId] else { return nil }
                return sidebarWorkspaceGroupTableConfiguration(
                    group: group,
                    memberWorkspaceIds: renderContext.memberWorkspaceIdsByGroupId[groupId] ?? [],
                    renderContext: renderContext
                )
            case .workspace(let workspaceId):
                guard let workspace = renderContext.workspaceById[workspaceId],
                      let input = workspaceRowInputsById[workspaceId] else { return nil }
                return workspaceTableRowConfiguration(
                    workspace,
                    input: input,
                    listSnapshot: listSnapshot,
                    renderContext: renderContext
                )
            }
        }
    }

    private func workspaceTableActions(
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableActions {
        var actions = SidebarWorkspaceTableActions(
            attachScrollView: { scrollView in
                dragAutoScrollController.attach(scrollView: scrollView)
            },
            closeWorkspace: { workspaceId in
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
#if DEBUG
                cmuxDebugLog("sidebar.close workspace=\(workspaceId.uuidString.prefix(5)) method=middleClick")
#endif
                tabManager.closeWorkspaceWithConfirmation(workspace)
            },
            createWorkspaceAtEnd: {
                if tabManager.selectedTab?.isRemoteTmuxMirror == true {
                    _ = AppDelegate.shared?.performNewWorkspaceAction(
                        tabManager: tabManager,
                        debugSource: "sidebar.emptyArea.remoteTmux"
                    )
                } else {
                    tabManager.addWorkspaceIfActive(placementOverride: .end)
                }
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            },
            createEmptyWorkspaceGroup: {
                _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
            },
            beginWorkspaceDrag: { workspaceId in
                _ = dragState.beginDragging(tabId: workspaceId)
            },
            movingWorkspaceCount: { workspaceId in
                SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
                    orderedWorkspaceIds: tabManager.tabs.map(\.id),
                    selectedIds: selectedTabIds,
                    draggedId: workspaceId,
                    anchorIds: Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
                ).count
            },
            endWorkspaceDrag: {
                dragState.finishDrag()
                dragAutoScrollController.stop()
            },
            isValidWorkspaceDrag: {
                dragState.currentWorkspaceDragId != nil
            },
            updateWorkspaceDrag: { point, targets, pasteboardWorkspaceId in
                updateWorkspaceReorderDropForTable(
                    point: point,
                    targets: targets,
                    pasteboardWorkspaceId: pasteboardWorkspaceId,
                    renderContext: renderContext
                )
            },
            performWorkspaceDrop: { point, targets, pasteboardWorkspaceId in
                performWorkspaceReorderDrop(
                    point: point,
                    targets: targets,
                    pasteboardWorkspaceId: pasteboardWorkspaceId,
                    renderContext: renderContext
                )
            },
            performPendingWorkspaceDrop: { pendingDrop, targets in
                performWorkspaceReorderDrop(
                    point: pendingDrop.point,
                    targets: targets,
                    pasteboardWorkspaceId: pendingDrop.workspaceId,
                    pendingSessionId: pendingDrop.sessionId,
                    renderContext: renderContext
                )
            },
            commitWorkspaceDropPlan: { plan in
                defer {
                    // The table source owns terminal cleanup. A successful
                    // drop only removes this view's transient presentation so
                    // its retained AppKit callback can fence the session.
                    dragState.dismissPresentation()
                    dragAutoScrollController.stop()
                }
                return performWorkspaceReorderPlan(plan)
            },
            clearWorkspaceDropIndicator: {
                dragState.clearDropIndicator()
                dragAutoScrollController.stop()
            },
            currentDropIndicator: {
                dragState.dropIndicator
            },
            currentDropIndicatorScope: {
                dragState.dropIndicatorScope
            },
            canPerformBonsplitAction: { action, transfer in
                guard let app = AppDelegate.shared else { return false }
                switch action {
                case .existingWorkspace(let workspaceId):
                    return app.canMoveBonsplitTab(tabId: transfer.tab.id, toWorkspace: workspaceId)
                case .newWorkspace:
                    return app.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id)
                }
            },
            moveBonsplitToExistingWorkspace: { workspaceId, transfer in
                guard let app = AppDelegate.shared else { return false }
                if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
                   source.workspaceId == workspaceId {
                    return true
                }
                return app.moveBonsplitTab(
                    tabId: transfer.tab.id,
                    toWorkspace: workspaceId,
                    focus: true,
                    focusWindow: true
                )
            },
            moveBonsplitToNewWorkspace: { insertionIndex, transfer in
                guard let app = AppDelegate.shared,
                      let result = app.moveBonsplitTabToNewWorkspace(
                        tabId: transfer.tab.id,
                        destinationManager: tabManager,
                        focus: true,
                        focusWindow: true,
                        insertionIndexOverride: insertionIndex
                      ) else {
                    return nil
                }
                return result.destinationWorkspaceId
            },
            didMoveBonsplitToWorkspace: { workspaceId in
                selectedTabIds = [workspaceId]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == workspaceId }
            },
            updateDragAutoscroll: {
                dragAutoScrollController.updateFromDragLocation()
            },
            setBonsplitDropTargetCollectionActive: { isActive in
                guard isBonsplitWorkspaceDropTargetCollectionActive != isActive else { return }
                isBonsplitWorkspaceDropTargetCollectionActive = isActive
            },
            setBonsplitDropIndicator: { indicator in
                dragState.setDropIndicator(indicator)
            },
            nativeWorkspaceDragLifecycle: SidebarWorkspaceTableActions.NativeWorkspaceDragLifecycle(
                currentSessionId: { dragState.currentWorkspaceDragSessionId },
                finish: { sessionId, capabilityValue in
                    dragState.finishDrag(
                        sessionId: sessionId,
                        capabilityValue: capabilityValue
                    )
                    dragAutoScrollController.stop()
                },
                reclaimSupersededNativeSources: { excludingSessionId in
                    dragState.reclaimSupersededNativeSources(
                        excludingSessionId: excludingSessionId
                    )
                }
            )
        )
        actions.workspaceGroupAnchorIdsForDrag = { [weak tabManager] in
            guard let tabManager else { return [:] }
            let liveWorkspaceIds = Set(tabManager.tabs.map(\.id))
            return Dictionary(
                uniqueKeysWithValues: tabManager.workspaceGroups.compactMap { group in
                    if group.isEmpty {
                        // Empty pinned groups still have a draggable header. Its
                        // stable group identity is consumed by the reorder
                        // resolver as `.reorderGroup`, not as a workspace id.
                        return (group.id, group.id)
                    }
                    guard liveWorkspaceIds.contains(group.anchorWorkspaceId) else { return nil }
                    return (group.id, group.anchorWorkspaceId)
                }
            )
        }
        return actions
    }

    /// Builds one pure-AppKit workspace row from the container-projected
    /// input (single source with the SwiftUI list: same snapshot, same
    /// context-menu aggregates, same selection path).
    private func workspaceTableRowConfiguration(
        _ tab: Workspace,
        input: SidebarWorkspaceRowInput,
        listSnapshot: SidebarWorkspaceRowsSnapshot,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        let environment = renderContext.environment
        let rowSnapshot = input.rowSnapshot(list: listSnapshot)
        let hintText: String? = {
            guard input.showsModifierShortcutHints || input.settings.alwaysShowShortcutHints,
                  let digit = input.workspaceShortcutDigit else { return nil }
            return "\(input.workspaceShortcutModifierSymbol)\(digit)"
        }()
        let model = SidebarWorkspaceRowModel(
            workspaceId: input.workspaceId,
            index: input.index,
            snapshot: input.workspace,
            settings: input.settings,
            isActive: input.isActive,
            isMultiSelected: input.isMultiSelected,
            hasUserCustomTitle: input.hasUserCustomTitle,
            canCloseWorkspace: input.canCloseWorkspace,
            accessibilityWorkspaceCount: input.workspaceCount,
            unreadCount: input.unreadCount,
            latestNotificationText: input.latestNotificationText,
            showsAgentActivity: input.showsAgentActivity,
            rowSpacing: input.rowSpacing,
            isBeingDragged: input.isBeingDragged,
            topDropIndicatorVisible: input.topDropIndicatorVisible,
            bottomDropIndicatorVisible: input.bottomDropIndicatorVisible,
            isGrouped: input.groupId != nil,
            isFirstRow: input.index == 0,
            shortcutHintText: hintText,
            showsShortcutHints: input.showsModifierShortcutHints,
            colorSchemeIsDark: environment.colorScheme == .dark,
            globalFontMagnificationPercent: environment.globalFontMagnificationPercent,
            isChecklistExpanded: input.isChecklistExpanded,
            checklistAddFieldActivationToken: input.checklistAddFieldActivationToken,
            isChecklistPopoverPresented: input.isChecklistPopoverPresented,
            editingChecklistItemId: editingChecklistItemIds[tab.id],
            todoControlsEnabled: WorkspaceTodoFeature.isEnabled,
            isMetadataExpanded: expandedMetadataWorkspaceIds.contains(tab.id),
            isMarkdownExpanded: expandedMarkdownWorkspaceIds.contains(tab.id)
        )
        let commands = SidebarWorkspaceRowCommands(
            tab: tab,
            tabManager: tabManager,
            notificationStore: notificationStore,
            index: input.index,
            contextMenuWorkspaceIds: rowSnapshot.contextMenu.targetWorkspaceIds,
            remoteContextMenuWorkspaceIds: rowSnapshot.contextMenu.remoteTargetWorkspaceIds,
            allRemoteContextMenuTargetsConnecting: rowSnapshot.contextMenu.allRemoteTargetsConnecting,
            allRemoteContextMenuTargetsDisconnected: rowSnapshot.contextMenu.allRemoteTargetsDisconnected,
            contextMenuPinState: rowSnapshot.contextMenu.pinState,
            workspaceGroupMenuSnapshot: rowSnapshot.contextMenu.groupMenuSnapshot,
            colorScheme: environment.colorScheme,
            refreshSnapshot: { [workspaceId = tab.id] in
                scheduleWorkspaceSnapshotRefresh(workspaceId: workspaceId)
            },
            readSelectedTabIds: { [selectedTabIds = $selectedTabIds] in selectedTabIds.wrappedValue },
            writeSelectedTabIds: { [selectedTabIds = $selectedTabIds] next in selectedTabIds.wrappedValue = next },
            readLastSelectionIndex: { [lastSidebarSelectionIndex = $lastSidebarSelectionIndex] in lastSidebarSelectionIndex.wrappedValue },
            writeLastSelectionIndex: { [lastSidebarSelectionIndex = $lastSidebarSelectionIndex] next in lastSidebarSelectionIndex.wrappedValue = next },
            setSelectionToTabs: { selection = .tabs },
            snapshotProvider: { [snapshot = input.workspace] in snapshot }
        )
        let openInBrowser: @MainActor (URL, Bool) -> Void = { [weak tabManager, workspaceId = tab.id] url, preferBrowser in
            if preferBrowser,
               let tabManager,
               tabManager.openBrowser(
                   inWorkspace: workspaceId,
                   url: url,
                   preferSplitRight: true,
                   insertAtEnd: true
               ) != nil {
                return
            }
            NSWorkspace.shared.open(url)
        }
        let rowActions = SidebarAppKitRowActions(
            commands: commands,
            onOpenStatusURL: { url in
                NSWorkspace.shared.open(url)
            },
            onOpenWorkspaceDescriptionURL: { url in
                NSWorkspace.shared.open(url)
            },
            onOpenPullRequest: { [prefer = input.settings.openPullRequestLinksInCmuxBrowser] url in
                openInBrowser(url, prefer)
            },
            onOpenPort: { [prefer = input.settings.openPortLinksInCmuxBrowser] port in
                guard let url = URL(string: "http://localhost:\(port)") else { return }
                openInBrowser(url, prefer)
            },
            onToggleChecklistExpansion: { [tabId = tab.id] in
                if expandedChecklistWorkspaceIds.contains(tabId) {
                    expandedChecklistWorkspaceIds.remove(tabId)
                } else {
                    expandedChecklistWorkspaceIds.insert(tabId)
                }
            },
            onToggleMetadataExpansion: { [tabId = tab.id] in
                if expandedMetadataWorkspaceIds.contains(tabId) {
                    expandedMetadataWorkspaceIds.remove(tabId)
                } else {
                    expandedMetadataWorkspaceIds.insert(tabId)
                }
            },
            onToggleMarkdownExpansion: { [tabId = tab.id] in
                if expandedMarkdownWorkspaceIds.contains(tabId) {
                    expandedMarkdownWorkspaceIds.remove(tabId)
                } else {
                    expandedMarkdownWorkspaceIds.insert(tabId)
                }
            },
            onConsumeChecklistAddFieldActivation: { [tabId = tab.id] in
                checklistAddFieldActivationTokens[tabId] = nil
            },
            checklistSetItemState: { [tab] itemId, state in
                WorkspaceTodoActions.setChecklistItemState(id: itemId, state: state, in: tab)
            },
            checklistRemoveItem: { [tab] itemId in
                WorkspaceTodoActions.removeChecklistItem(id: itemId, from: tab)
            },
            checklistAddItem: { [tab] text in
                WorkspaceTodoActions.addChecklistItem(text: text, to: tab)
            },
            checklistEditItem: { [tab] itemId, text in
                WorkspaceTodoActions.editChecklistItem(id: itemId, text: text, in: tab)
            },
            checklistMoveItem: { [tab] itemId, toIndex in
                WorkspaceTodoActions.moveChecklistItem(id: itemId, toIndex: toIndex, in: tab)
            },
            checklistOpenPane: { [tab] in
                WorkspaceTodoActions.openTodoPane(for: tab)
            },
            checklistAddAttachments: { [tab] itemId in
                WorkspaceTodoActions.addImageAttachments(to: itemId, in: tab)
            },
            checklistRemoveAttachment: { [tab] itemId, attachmentId in
                WorkspaceTodoActions.removeImageAttachment(itemId: itemId, attachmentId: attachmentId, from: tab)
            },
            checklistOpenAttachments: { [tab] itemId, selectedAttachmentId in
                guard let item = tab.todoState.checklist.first(where: { $0.id == itemId }) else { return }
                WorkspaceTodoActions.openImageAttachments(
                    item.attachments,
                    selectedAttachmentId: selectedAttachmentId
                )
            },
            onChecklistPopoverPresentedChange: { [tabId = tab.id] presented in
                if presented {
                    checklistPopoverWorkspaceId = tabId
                } else if checklistPopoverWorkspaceId == tabId {
                    checklistPopoverWorkspaceId = nil
                }
            },
            onBeginChecklistItemEdit: { [tabId = tab.id] itemId in
                if let itemId {
                    editingChecklistItemIds[tabId] = itemId
                } else {
                    editingChecklistItemIds[tabId] = nil
                }
            },
            onEndChecklistItemEdit: { [tabId = tab.id] itemId in
                if editingChecklistItemIds[tabId] == itemId {
                    editingChecklistItemIds[tabId] = nil
                }
            },
            applyTodoStatus: { [tab] status in
                WorkspaceTodoActions.applyStatusOverride(status, to: [tab])
            },
            hideTodoStatus: { [tab] in
                WorkspaceTodoActions.hideStatus(for: [tab])
            },
            commitRename: { [weak tabManager, workspaceId = tab.id] text in
                tabManager?.setCustomTitle(tabId: workspaceId, title: text)
            }
        )
        return SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: rowActions,
            groupId: input.groupId,
            isPinned: input.workspace.isPinned,
            environment: environment,
            unreadRebuild: {
                [model, workspaceId = tab.id,
                 showsNotificationMessage = input.settings.showsNotificationMessage] snapshot in
                let summary = snapshot.summary(forWorkspaceId: workspaceId)
                var fresh = model
                fresh.unreadCount = summary.unreadCount
                fresh.latestNotificationText = showsNotificationMessage
                    ? summary.latestNotificationText
                    : nil
                return fresh
            }
        )
    }


    // Applies one stable overlay/autohide scroller config and never toggles it.
    // Toggling `hasVerticalScroller`/style from SwiftUI re-renders (constant
    // while agents update rows) re-flashes the overlay knob so it never reaches
    // its idle fade; a stable config lets AppKit own appear/scroll/fade and the
    // finite empty-area height keeps it hidden when content fits (#3241).
    private func configureSidebarScrollView(_ scrollView: NSScrollView?) {
        guard let scrollView else { return }
        scrollView.applySidebarOverlayScrollerConfiguration()
    }

    private func extensionSidebarScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        extensionSidebarScrollAreaContent(renderContext: renderContext)
            .sidebarCloudBindingObservations(ids: renderContext.workspaceIds, models: renderContext.tabs.map(\.cloudBindingState)) { refreshExtensionSidebarSnapshot() }
            .sidebarProcessTitleObservations(ids: renderContext.workspaceIds, models: renderContext.tabs.map(\.sidebarProcessTitleObservation)) { refreshExtensionSidebarSnapshot() }
            .onAppear { refreshExtensionSidebarObservationPublishers(tabs: renderContext.tabs) }
            .onChange(of: renderContext.workspaceIds) { _, _ in
                refreshExtensionSidebarObservationPublishers(tabs: renderContext.tabs)
            }
            .onDisappear {
                clearExtensionSidebarObservationPublishers()
            }
    }

    @ViewBuilder
    private func extensionSidebarScrollAreaContent(renderContext: WorkspaceListRenderContext) -> some View {
        if effectiveExtensionSidebarProviderId == CmuxExtensionSidebarSelection.hostedExtensionsProviderId {
            CMUXInstalledExtensionSidebarHostView(
                snapshotProvider: { cmuxSidebarSnapshotForCurrentTabs() },
                snapshotUpdateToken: extensionSidebarUpdateToken,
                unreadSource: sidebarUnread,
                actionHandler: { handleCMUXSidebarExtensionAction($0) },
                onUseDefaultSidebar: {
                    CmuxExtensionSidebarSelection.setProviderId(CmuxSidebarProviderDescriptor.defaultWorkspacesID)
                }
            )
            .onReceive(extensionSidebarImmediateObservationPublisher) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(extensionSidebarDebouncedObservationPublisher) { _ in
                refreshExtensionSidebarSnapshot()
            }
            // Fade the extension's content out at the bottom so it dissolves behind the
            // sidebar footer instead of overlapping it sharply, matching the default
            // workspace sidebar's bottom scrim. Top stays sharp so the control strip
            // remains crisp.
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: 0,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else if effectiveExtensionSidebarProviderId.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix),
                  let customSidebarURL = CmuxExtensionSidebarSelection.customSidebarFileURL(forProviderId: effectiveExtensionSidebarProviderId) {
            // Periodic tick so the custom sidebar re-renders live (clock,
            // countdowns, and refreshed workspace/data context), mirroring the
            // default sidebar's TimelineView. No banned timers involved.
            // The surface mounts the in-process renderer by default (native
            // hover/focus/keyboard, same-frame resize); the
            // `customSidebars.renderer` setting switches it to the
            // out-of-process worker for untrusted sources (no file-derived
            // view code runs in the host). The @LiveSetting's initial value
            // lags one store round-trip on remount, so a non-default choice
            // can mount the other renderer for one tick before flipping;
            // harmless (the host shuts the short-lived client down on
            // unmount).
            SidebarUnreadSnapshotReader(source: sidebarUnread) { unreadSnapshot in
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    CustomSidebarSurface(
                        fileURL: customSidebarURL,
                        dataContext: customSidebarDataContext(
                            now: timeline.date,
                            unreadSnapshot: unreadSnapshot
                        ),
                        dispatch: makeCmuxSidebarActionDispatch(),
                        contentInsets: CustomSidebarContentInsets(
                            top: SidebarWorkspaceScrollInsets.workspaceList.top,
                            bottom: SidebarWorkspaceScrollInsets.workspaceList.bottom
                        ),
                        rendersInProcess: customSidebarRenderer == .inProcess,
                        client: $sidebarRenderWorkerClient
                    )
                }
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else {
            SidebarUnreadSnapshotReader(source: sidebarUnread) { unreadSnapshot in
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    let model = extensionSidebarRenderModel(
                        renderContext: renderContext,
                        unreadSnapshot: unreadSnapshot,
                        now: timeline.date
                    )
                    extensionSidebarTimelineContent(
                        renderContext: renderContext,
                        model: model,
                        now: timeline.date
                    )
                }
            }
        }
    }

    private func extensionSidebarTimelineContent(
        renderContext: WorkspaceListRenderContext,
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        GeometryReader { geometryProxy in
            ScrollView {
                if model.presentation == .browserStack {
                    extensionBrowserStackSidebar(model: model, now: now)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                                viewportHeight: geometryProxy.size.height,
                                insets: SidebarWorkspaceScrollInsets.workspaceList
                            ),
                            alignment: .topLeading
                        )
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sections) { section in
                            extensionSidebarSection(section, providerId: model.providerId, now: now)
                        }

                        SidebarEmptyArea(
                            rowSpacing: tabRowSpacing,
                            selection: $selection,
                            selectedTabIds: $selectedTabIds,
                            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                            dragAutoScrollController: dragAutoScrollController,
                            topDropIndicatorVisible: emptyAreaTopDropIndicatorVisible(),
                            tabDropDelegate: emptyAreaTabDropDelegate(renderContext: renderContext),
                            bonsplitDropIndicator: dropIndicatorBinding
                        )
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .padding(.top, SidebarWorkspaceListMetrics.rowVerticalPadding)
                    .padding(.bottom, SidebarWorkspaceListMetrics.rowVerticalPadding + 40)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                            viewportHeight: geometryProxy.size.height,
                            insets: SidebarWorkspaceScrollInsets.workspaceList
                        ),
                        alignment: .topLeading
                    )
                }
            }
            .coordinateSpace(name: SidebarPointerInteractionMonitor.coordinateSpaceName)
            .sidebarPointerEventHost(pointerInteractionMonitor)
            .background(
                SidebarScrollViewResolver { scrollView in
                    configureSidebarScrollView(scrollView)
                    dragAutoScrollController.attach(scrollView: scrollView)
                }
                .frame(width: 0, height: 0)
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: SidebarWorkspaceScrollInsets.workspaceList.top)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SidebarWorkspaceScrollInsets.workspaceList.bottom)
                    .allowsHitTesting(false)
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
            .overlay(alignment: .top) {
                WindowDragHandleView()
                    .frame(height: sidebarTitlebarInteractionHeight)
                    .background(TitlebarDoubleClickMonitorView())
            }
            .overlay(alignment: .topLeading) {
                minimalModeSidebarTitlebarControlsOverlay()
            }
            .background(Color.clear)
            .modifier(ClearScrollBackground())
            .onReceive(extensionSidebarImmediateObservationPublisher) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(extensionSidebarDebouncedObservationPublisher) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: BrowserStackSidebar.stateDidLoadNotification)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
        }
    }

    private func refreshExtensionSidebarSnapshot() {
        extensionSidebarUpdateToken &+= 1
    }

    private func scheduleWorkspaceSnapshotRefresh(workspaceId: UUID) {
        workspaceSnapshotRefreshCoalescer.schedule(workspaceId: workspaceId) { workspaceIds in
            refreshWorkspaceSnapshots(workspaceIds: workspaceIds)
        }
    }

    private func refreshWorkspaceSnapshots(workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        let workspaceById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0) })
        let settings = tabItemSettingsStore.snapshot
        let showsAgentActivity = settings.details.showAgentActivity
            && CmuxFeatureFlags.shared.isSidebarWorkspaceAgentSpinnerEnabled
        var next = workspaceSnapshotsById
        var changed = false
        for workspaceId in workspaceIds {
            guard let workspace = workspaceById[workspaceId] else {
                changed = next.removeValue(forKey: workspaceId) != nil || changed
                continue
            }
            let snapshot = makeWorkspaceSnapshot(
                workspace: workspace,
                settings: settings,
                showsAgentActivity: showsAgentActivity
            )
            if featureFlags.isAppKitSidebarListEnabled {
                guard appKitRowSnapshotCache.value(for: workspaceId) != snapshot else {
                    continue
                }
                appKitRowSnapshotCache.store(snapshot, for: workspaceId)
            }
            guard next[workspaceId] != snapshot else { continue }
            next[workspaceId] = snapshot
            changed = true
        }
        guard changed else { return }
#if DEBUG
        cmuxDebugLog("sidebar.snapshot.refresh requested=\(workspaceIds.count)")
#endif
        workspaceSnapshotsById = next
    }

    private func refreshWorkspaceSnapshots() {
        workspaceSnapshotRefreshCoalescer.cancel()
        let tabs = tabManager.tabs
        let liveIds = Set(tabs.map(\.id))
        let settings = tabItemSettingsStore.snapshot
        let showsAgentActivity = settings.details.showAgentActivity
            && CmuxFeatureFlags.shared.isSidebarWorkspaceAgentSpinnerEnabled
        var next: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
        next.reserveCapacity(tabs.count)
        for workspace in tabs {
            next[workspace.id] = makeWorkspaceSnapshot(
                workspace: workspace,
                settings: settings,
                showsAgentActivity: showsAgentActivity
            )
        }
        guard next != workspaceSnapshotsById || Set(workspaceSnapshotsById.keys) != liveIds else { return }
        workspaceSnapshotsById = next
    }

    private func makeWorkspaceSnapshot(
        workspace: Workspace,
        settings: SidebarTabItemSettingsSnapshot,
        showsAgentActivity: Bool
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
#if DEBUG
        sidebarLazyContractProbe.workspaceSnapshotBuild?()
#endif
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: showsAgentActivity
        ).makeSnapshot()
    }

    private func clearExtensionSidebarObservationPublishers() {
        extensionSidebarObservationWorkspaceIds = []
        extensionSidebarObservationPublishersBuilt = false
        extensionSidebarImmediateObservationPublisher = Empty<Void, Never>().eraseToAnyPublisher()
        extensionSidebarDebouncedObservationPublisher = Empty<Void, Never>().eraseToAnyPublisher()
    }

    private func refreshExtensionSidebarObservationPublishers(tabs: [Workspace]) {
        let workspaceIds = tabs.map(\.id)
        guard !extensionSidebarObservationPublishersBuilt ||
              workspaceIds != extensionSidebarObservationWorkspaceIds
        else { return }

        extensionSidebarObservationPublishersBuilt = true
        extensionSidebarObservationWorkspaceIds = workspaceIds

        guard !tabs.isEmpty else {
            extensionSidebarImmediateObservationPublisher = Empty<Void, Never>().eraseToAnyPublisher()
            extensionSidebarDebouncedObservationPublisher = Empty<Void, Never>().eraseToAnyPublisher()
            return
        }

        extensionSidebarImmediateObservationPublisher =
            Workspace.mergedImmediateObservationPublisher(for: tabs)
        extensionSidebarDebouncedObservationPublisher = Publishers.MergeMany(
            tabs.map { $0.sidebarObservationPublisher }
        )
        .receive(on: RunLoop.main)
        .debounce(for: Self.extensionSidebarObservationCoalesceInterval, scheduler: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    private func extensionSidebarRenderModel(
        renderContext: WorkspaceListRenderContext,
        unreadSnapshot: SidebarUnreadSnapshot,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        let _ = extensionSidebarUpdateToken
        let snapshot = extensionSidebarSnapshot(
            renderContext: renderContext,
            unreadSnapshot: unreadSnapshot
        )
        return extensionSidebarRenderModel(snapshot: snapshot, now: now)
    }

    private func extensionSidebarRenderModel(
        snapshot: CmuxSidebarProviderSnapshot,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        // Look up the provider directly by the effective id instead of round-
        // tripping through `descriptor(for:)`, which rebuilds the full
        // `descriptors` list (SettingCatalog + custom-sidebars directory scan)
        // on every TimelineView tick. See issue #5970.
        let providerId = effectiveExtensionSidebarProviderId
        if let provider = CmuxExtensionSidebarSelection.provider(for: providerId) {
            let context = CmuxSidebarProviderRenderContext(now: now)
            if let contextualProvider = provider as? any CmuxContextualSidebarProvider {
                return contextualProvider.render(snapshot: snapshot, context: context)
            }
            return provider.render(snapshot: snapshot)
        }
        return CmuxSidebarProviderRenderModel(
            providerId: providerId,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    private func extensionSidebarSnapshot(
        renderContext: WorkspaceListRenderContext,
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(
            workspaces: renderContext.tabs,
            unreadSnapshot: unreadSnapshot
        )
    }

    private func extensionSidebarSnapshotForCurrentTabs() -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(
            workspaces: tabManager.tabs,
            unreadSnapshot: sidebarUnread.snapshot
        )
    }

    private func cmuxSidebarSnapshotForCurrentTabs() -> CmuxSidebarSnapshot {
        let snapshot = extensionSidebarSnapshotForCurrentTabs()
        return CmuxSidebarSnapshot(
            sequence: snapshot.sequence,
            windowID: snapshot.windowId,
            selectedWorkspaceID: snapshot.selectedWorkspaceId,
            workspaces: snapshot.workspaces.map { workspace in
                CmuxSidebarWorkspace(
                    id: workspace.id,
                    title: workspace.title,
                    detail: workspace.customDescription,
                    isPinned: workspace.isPinned,
                    rootPath: workspace.rootPath,
                    projectRootPath: workspace.projectRootPath,
                    gitBranch: workspace.branchSummary,
	                    unreadCount: workspace.unreadCount,
	                    latestNotification: workspace.latestNotificationText,
	                    listeningPorts: workspace.listeningPorts,
	                    pullRequestURLs: workspace.pullRequestURLs,
	                    surfaces: cmuxSidebarSurfaces(for: workspace)
	                )
	            }
	        )
	    }

    private func cmuxSidebarSurfaces(for workspace: CmuxSidebarProviderWorkspace) -> [CmuxSidebarSurface] {
        guard let liveWorkspace = tabManager.tabs.first(where: { $0.id == workspace.id }) else { return [] }
        return liveWorkspace.sidebarOrderedPanelIds().compactMap { panelId in
            guard let panel = liveWorkspace.panels[panelId] else { return nil }
            return CmuxSidebarSurface(
                id: panelId,
                title: liveWorkspace.panelTitle(panelId: panelId) ?? panel.displayTitle,
                kind: cmuxSidebarSurfaceKind(for: panel.panelType),
                isFocused: liveWorkspace.focusedPanelId == panelId,
                isPinned: liveWorkspace.isPanelPinned(panelId),
                unreadCount: liveWorkspace.manualUnreadPanelIds.contains(panelId) ? 1 : 0,
                workingDirectory: liveWorkspace.reportedPanelDirectory(panelId: panelId)
            )
        }
    }
    private func handleCMUXSidebarExtensionAction(
        _ action: CmuxSidebarAction
    ) -> CmuxSidebarActionResult {
        switch action {
        case .createWorkspace(let title, let workingDirectory, let select):
            guard let workspace = tabManager.addWorkspaceIfActive(
                title: title,
                workingDirectory: workingDirectory,
                inheritWorkingDirectory: workingDirectory == nil,
                select: select
            ) else {
                return CmuxSidebarActionResult(accepted: false)
            }
            return CmuxSidebarActionResult(accepted: true, message: workspace.id.uuidString)

        case .selectWorkspace(let workspaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found")
                )
            }
            tabManager.selectWorkspace(workspace)
            return .accepted

        case .closeWorkspace(let workspaceId):
            guard tabManager.closeWorkspaceWithConfirmation(tabId: workspaceId) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.closeRejected", defaultValue: "Workspace could not be closed")
                )
            }
            return .accepted

        case .selectNextWorkspace:
            tabManager.selectNextTab()
            return .accepted

        case .selectPreviousWorkspace:
            tabManager.selectPreviousTab()
            return .accepted

        case .createTerminalSurface(let workspaceId):
            guard let workspace = workspaceId.flatMap({ id in tabManager.tabs.first(where: { $0.id == id }) }) ?? tabManager.selectedWorkspace else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            let panel = workspace.newTerminalSurfaceInFocusedPane(focus: true, initialInput: nil)
            if panel == nil, workspace.isRemoteTmuxMirror {
                // Routed to the remote as a tmux `new-window`; the tab arrives
                // asynchronously via the mirror, so this is success, not failure.
                return CmuxSidebarActionResult(
                    accepted: true,
                    message: String(localized: "sidebar.extensions.action.remoteTmuxWindowRequested", defaultValue: "Remote tmux window requested")
                )
            }
            return panel.map { CmuxSidebarActionResult(accepted: true, message: $0.id.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .createBrowserSurface(let workspaceId, let urlString):
            let validatedURL = cmuxSidebarExtensionOptionalHTTPURL(from: urlString)
            guard validatedURL.accepted else {
                return .rejected(String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened"))
            }
            guard let workspace = workspaceId.flatMap({ id in tabManager.tabs.first(where: { $0.id == id }) }) ?? tabManager.selectedWorkspace else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            let panelId = tabManager.createBrowserSplit(direction: .right, url: validatedURL.url)
            return panelId.map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .selectSurface(let workspaceId, let surfaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  workspace.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            tabManager.selectWorkspace(workspace)
            workspace.focusPanel(surfaceId)
            return .accepted

        case .selectNextSurface:
            tabManager.selectNextSurface()
            return .accepted

        case .selectPreviousSurface:
            tabManager.selectPreviousSurface()
            return .accepted

        case .closeSurface(let workspaceId, let surfaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            guard workspace.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            tabManager.closePanelWithConfirmation(tabId: workspaceId, surfaceId: surfaceId)
            return .accepted

        case .splitTerminal(let workspaceId, let surfaceId, let direction):
            let outcome = splitDirection(from: direction).map { tabManager.createSplitOutcome(tabId: workspaceId, surfaceId: surfaceId, direction: $0) }
            guard let outcome, outcome.isAccepted else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            return CmuxSidebarActionResult(accepted: true, message: outcome.panel?.id.uuidString)

        case .splitBrowser(let workspaceId, let surfaceId, let direction, let urlString):
            let validatedURL = cmuxSidebarExtensionOptionalHTTPURL(from: urlString)
            guard validatedURL.accepted else {
                return .rejected(String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened"))
            }
            guard let splitDirection = splitDirection(from: direction),
                  let tab = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  tab.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            tabManager.selectWorkspace(tab)
            tab.focusPanel(surfaceId)
            let panelId = tabManager.createBrowserSplit(direction: splitDirection, url: validatedURL.url)
            return panelId.map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .toggleSurfaceZoom(let workspaceId, let surfaceId):
            guard tabManager.toggleSplitZoom(tabId: workspaceId, surfaceId: surfaceId) else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            return .accepted

        case .openURL(let urlString):
            guard let url = cmuxSidebarExtensionRequiredHTTPURL(from: urlString),
                  NSWorkspace.shared.open(url) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened")
                )
            }
            return .accepted
        }
    }

    private func cmuxSidebarExtensionOptionalHTTPURL(from urlString: String?) -> (url: URL?, accepted: Bool) {
        guard let urlString, !urlString.isEmpty else {
            return (nil, true)
        }
        guard let url = cmuxSidebarExtensionRequiredHTTPURL(from: urlString) else {
            return (nil, false)
        }
        return (url, true)
    }

    private func cmuxSidebarExtensionRequiredHTTPURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    private func splitDirection(from direction: CmuxSidebarSplitDirection) -> SplitDirection? {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    private func extensionSidebarSnapshot(
        workspaces: [Workspace],
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> CmuxSidebarProviderSnapshot {
        CmuxSidebarProviderSnapshot(
            sequence: UInt64(max(0, CmuxEventBus.shared.latestSequence)),
            selectedWorkspaceId: tabManager.selectedTabId,
            workspaces: workspaces.map {
                extensionWorkspaceSnapshot(for: $0, unreadSnapshot: unreadSnapshot)
            },
            windowId: windowId
        )
    }

    private func extensionWorkspaceSnapshot(
        for workspace: Workspace,
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> CmuxSidebarProviderWorkspace {
        let rootPath = extensionSidebarRootPath(for: workspace)
        return CmuxSidebarProviderWorkspace(
            id: workspace.id,
            title: workspace.title,
            customDescription: workspace.customDescription,
            isPinned: workspace.isPinned,
            rootPath: rootPath,
            projectRootPath: workspace.extensionSidebarProjectRootPath,
            branchSummary: workspace.sidebarGitBranchesInDisplayOrder().first?.branch,
            remoteDisplayTarget: workspace.remoteDisplayTarget,
            remoteConnectionState: workspace.remoteConnectionState.rawValue,
            unreadCount: unreadSnapshot.unreadCount(forWorkspaceId: workspace.id),
            latestNotificationText: unreadSnapshot.latestNotificationText(forWorkspaceId: workspace.id),
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            listeningPorts: workspace.listeningPorts,
            pullRequestURLs: workspace.sidebarPullRequestsInDisplayOrder().map { $0.url.absoluteString },
            panelDirectories: workspace.sidebarFilesystemDirectoriesInDisplayOrder(),
            gitBranches: workspace.sidebarGitBranchesInDisplayOrder().map {
                CmuxSidebarProviderGitBranch(branch: $0.branch, isDirty: $0.isDirty)
            }
        )
    }

    private func extensionSidebarRootPath(for workspace: Workspace) -> String? {
        workspace.presentedCurrentDirectory?.nilIfEmpty
    }

    private func extensionBrowserStackSidebar(
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        let rows = model.sections.flatMap(\.rows)
        let tileRows = model.sections.first { $0.id == "tiles" }?.rows ?? Array(rows.prefix(3))
        let looseRows = model.sections.first { $0.id == "loose" }?.rows ?? Array(rows.dropFirst(3).prefix(5))
        let groupedSections = model.sections.filter { $0.id != "tiles" && $0.id != "loose" && !$0.rows.isEmpty }
        let dropRows = extensionBrowserStackDropRows(for: model)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(stride(from: 0, to: tileRows.count, by: 3)), id: \.self) { rowStart in
                    HStack(spacing: 8) {
                        ForEach(Array(tileRows[rowStart..<min(rowStart + 3, tileRows.count)].enumerated()), id: \.element.id) { offset, row in
                            let index = rowStart + offset
                            extensionBrowserStackTile(
                                row: row,
                                isSelected: row.workspaceId == tabManager.selectedTabId
                                    || (tabManager.selectedTabId == nil && index == 0),
                                dropRows: dropRows
                            )
                        }
                        if tileRows.count - rowStart < 3 {
                            ForEach(0..<(3 - (tileRows.count - rowStart)), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(looseRows) { row in
                    extensionBrowserStackRow(
                        row: row,
                        now: now,
                        isSelected: row.workspaceId == tabManager.selectedTabId,
                        dropRows: dropRows
                    )
                }
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(groupedSections) { section in
                    extensionBrowserStackGroup(section: section, now: now, dropRows: dropRows)
                }
            }

            Button(action: onNewTab) {
                HStack(spacing: 9) {
                    CmuxSystemSymbolImage(magnified: "plus", pointSize: 15, weight: .regular, tint: .secondary)
                        .frame(width: 22, height: 22)
                    Text(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab"))
                        .cmuxFont(size: 13, weight: .regular)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab"))

            ExtensionSidebarBrowserStackEmptyArea(
                rowSpacing: tabRowSpacing,
                orderedRows: dropRows,
                dragAutoScrollController: dragAutoScrollController,
                draggedTabId: draggedTabIdBinding,
                dropIndicator: dropIndicatorBinding,
                onNewTab: onNewTab,
                onMove: { move in
                    handleExtensionSidebarMutation(.moveWorkspace(move))
                }
            )
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(.bottom, SidebarWorkspaceListMetrics.rowVerticalPadding + 40)
    }

    private func extensionBrowserStackGroup(
        section: CmuxSidebarProviderSection,
        now: Date,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                CmuxSystemSymbolImage(magnified: "folder.fill", pointSize: 14, weight: .regular, tint: .secondary)
                Text(extensionSidebarTreeSectionTitle(section.treeSection))
                    .cmuxFont(size: 13, weight: .semibold)
                    .foregroundColor(.primary.opacity(0.86))
                    .lineLimit(1)
                CmuxSystemSymbolImage(magnified: "chevron.down", pointSize: 11, weight: .medium, tint: .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.rows) { row in
                    extensionBrowserStackRow(
                        row: row,
                        now: now,
                        compact: true,
                        isSelected: row.workspaceId == tabManager.selectedTabId,
                        dropRows: dropRows
                    )
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
    }

    private func extensionBrowserStackTile(
        row: CmuxSidebarProviderRow,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        let targetRowHeight: CGFloat = 54

        return Button {
            selectExtensionSidebarWorkspace(row.workspaceId)
        } label: {
            extensionBrowserStackIcon(row.leadingIcon, size: 28)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            isSelected
                                ? Color(red: 0.44, green: 0.29, blue: 0.23).opacity(0.9)
                                : Color.primary.opacity(0.10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    isSelected ? Color.red.opacity(0.85) : Color.primary.opacity(0.08),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .safeHelp(row.title)
        .opacity(dragState.draggedTabId == row.workspaceId ? 0.55 : 1)
        .sidebarPointerFrameReporting(
            onFrameChange: { [pointerInteractionMonitor, workspaceId = row.workspaceId] frame in
                pointerInteractionMonitor.updateFrame(
                    frame,
                    for: .workspace(workspaceId),
                    workspaceId: workspaceId
                )
            },
            onDisappear: { [pointerInteractionMonitor, workspaceId = row.workspaceId] in
                pointerInteractionMonitor.removeFrame(for: .workspace(workspaceId))
            }
        )
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackDropDelegate(
            targetWorkspaceId: row.workspaceId,
            orderedRows: dropRows,
            draggedTabId: draggedTabIdBinding,
            targetRowHeight: targetRowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: dropIndicatorBinding,
            onMove: { move in
                handleExtensionSidebarMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            extensionBrowserStackDropIndicator(row: row, edge: .top)
        }
        .overlay(alignment: .bottom) {
            extensionBrowserStackDropIndicator(row: row, edge: .bottom)
        }
        .contextMenu {
            extensionBrowserStackReorderMenu(row: row)
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    private func extensionBrowserStackRow(
        row: CmuxSidebarProviderRow,
        now: Date,
        compact: Bool = false,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        let targetRowHeight: CGFloat = compact ? 34 : 38

        return Button {
            selectExtensionSidebarWorkspace(row.workspaceId)
        } label: {
            HStack(spacing: 9) {
                extensionBrowserStackIcon(row.leadingIcon, size: compact ? 22 : 24)
                Text(row.title)
                    .cmuxFont(size: compact ? 12.5 : 13, weight: .medium)
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let trailing = extensionSidebarRenderedText(row.trailingText, now: now) {
                    Text(trailing)
                        .cmuxFont(size: 11, weight: .regular)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(isSelected ? cmuxAccentColor().opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dragState.draggedTabId == row.workspaceId ? 0.55 : 1)
        .sidebarPointerFrameReporting(
            onFrameChange: { [pointerInteractionMonitor, workspaceId = row.workspaceId] frame in
                pointerInteractionMonitor.updateFrame(
                    frame,
                    for: .workspace(workspaceId),
                    workspaceId: workspaceId
                )
            },
            onDisappear: { [pointerInteractionMonitor, workspaceId = row.workspaceId] in
                pointerInteractionMonitor.removeFrame(for: .workspace(workspaceId))
            }
        )
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackDropDelegate(
            targetWorkspaceId: row.workspaceId,
            orderedRows: dropRows,
            draggedTabId: draggedTabIdBinding,
            targetRowHeight: targetRowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: dropIndicatorBinding,
            onMove: { move in
                handleExtensionSidebarMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            extensionBrowserStackDropIndicator(row: row, edge: .top)
        }
        .overlay(alignment: .bottom) {
            extensionBrowserStackDropIndicator(row: row, edge: .bottom)
        }
        .contextMenu {
            extensionBrowserStackReorderMenu(row: row)
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    @ViewBuilder
    private func extensionBrowserStackDropIndicator(
        row: CmuxSidebarProviderRow,
        edge: SidebarDropEdge
    ) -> some View {
        if dragState.dropIndicator == SidebarDropIndicator(tabId: row.workspaceId, edge: edge) {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(height: 2)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func extensionBrowserStackReorderMenu(row: CmuxSidebarProviderRow) -> some View {
        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    private func moveExtensionBrowserStackWorkspace(_ workspaceId: UUID, by delta: Int) {
        let snapshot = extensionSidebarSnapshotForCurrentTabs()
        let model = extensionSidebarRenderModel(snapshot: snapshot, now: Date())
        let dropRows = extensionBrowserStackDropRows(for: model)
        guard let currentIndex = dropRows.firstIndex(where: { $0.workspaceId == workspaceId }) else { return }
        let targetIndex = min(max(currentIndex + delta, 0), dropRows.count - 1)
        guard targetIndex != currentIndex else { return }
        let insertionPosition = delta > 0 ? targetIndex + 1 : targetIndex
        guard let move = extensionBrowserStackMove(
            workspaceId: workspaceId,
            insertionPosition: insertionPosition,
            orderedRows: dropRows
        ) else {
            NSSound.beep()
            return
        }
        guard handleExtensionSidebarMutation(.moveWorkspace(move)) else {
            NSSound.beep()
            return
        }
    }

    private func handleExtensionSidebarMutation(_ mutation: CmuxSidebarProviderMutation) -> Bool {
        let descriptor = CmuxExtensionSidebarSelection.descriptor(for: effectiveExtensionSidebarProviderId)
        guard let provider = CmuxExtensionSidebarSelection.provider(for: descriptor.id) as? any CmuxMutableSidebarProvider else {
            return false
        }
        do {
            let result = try provider.handle(mutation, snapshot: extensionSidebarSnapshotForCurrentTabs())
            if result.ok {
                refreshExtensionSidebarSnapshot()
            }
            return result.ok
        } catch {
#if DEBUG
            cmuxDebugLog("extension.sidebar.mutation.failed provider=\(descriptor.id) error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    private func extensionBrowserStackDropRows(
        for model: CmuxSidebarProviderRenderModel
    ) -> [ExtensionSidebarBrowserStackDropRow] {
        model.sections.flatMap { section in
            section.rows.map { row in
                ExtensionSidebarBrowserStackDropRow(
                    workspaceId: row.workspaceId,
                    sectionId: section.id
                )
            }
        }
    }

    private func extensionBrowserStackMove(
        workspaceId: UUID,
        insertionPosition: Int,
        orderedRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> CmuxSidebarProviderWorkspaceMove? {
        ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
            draggedWorkspaceId: workspaceId,
            insertionPosition: insertionPosition
        )
    }

    private func extensionSidebarWorkspaceSnapshotsById(
        for rows: [CmuxSidebarProviderRow]
    ) -> [UUID: CmuxSidebarProviderWorkspace] {
        var snapshotsById: [UUID: CmuxSidebarProviderWorkspace] = [:]
        for row in rows where snapshotsById[row.workspaceId] == nil {
            snapshotsById[row.workspaceId] = extensionWorkspaceSnapshot(for: row.workspaceId)
        }
        return snapshotsById
    }

    private func extensionBrowserStackIcon(
        _ icon: CmuxSidebarProviderIcon?,
        size: CGFloat
    ) -> some View {
        let shape = icon?.shape ?? .circle
        let foreground = extensionSidebarColor(hex: icon?.foregroundColorHex, fallback: .primary)
        let background = extensionSidebarColor(hex: icon?.backgroundColorHex, fallback: Color.primary.opacity(0.16))
        return ZStack {
            if shape == .circle {
                Circle().fill(background)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(background)
            }
            if let systemImageName = icon?.systemImageName {
                CmuxSystemSymbolImage(magnified: systemImageName, pointSize: size * 0.58, weight: .semibold, tint: foreground)
            } else {
                Text(icon?.text ?? ".")
                    .cmuxFont(size: size * 0.58, weight: .bold)
                    .foregroundColor(foreground)
            }
        }
        .frame(width: size, height: size)
    }

    private func extensionSidebarRenderedText(_ text: CmuxSidebarProviderText?, now: Date) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return CmuxExtensionSidebarSelection.localizedText(localized)
        case .relativeDate(let date, _):
            return CmuxExtensionRelativeTimeFormatter.string(from: date, to: now)
        }
    }

    private func extensionSidebarColor(hex: String?, fallback: Color) -> Color {
        guard let hex else { return fallback }
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6 else { return fallback }
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else { return fallback }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    @ViewBuilder
    private func extensionSidebarSection(
        _ section: CmuxSidebarProviderSection,
        providerId: String,
        now: Date
    ) -> some View {
        let isCollapsed = collapsedExtensionSidebarSectionIds.contains(section.id)
        let canCreateWorktree = section.treeSection.projectRootPath != nil
        let selectedWorkspaceId = tabManager.selectedTabId
        let workspaceSnapshotsById = extensionSidebarWorkspaceSnapshotsById(for: section.rows)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Button {
                    withAnimation(Self.extensionSidebarDisclosureAnimation) {
                        if isCollapsed {
                            collapsedExtensionSidebarSectionIds.remove(section.id)
                        } else {
                            collapsedExtensionSidebarSectionIds.insert(section.id)
                        }
                    }
                } label: {
                    CmuxSystemSymbolImage(magnified: isCollapsed ? "folder" : "folder.fill", pointSize: 13, weight: .regular, tint: .primary)
                        .offset(y: -0.5)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.toggleSection", defaultValue: "Toggle section"))

                Text(extensionSidebarTreeSectionTitle(section.treeSection))
                    .cmuxFont(size: 12, weight: .regular)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if canCreateWorktree {
                    let worktreeButtonSymbol = extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id)
                        ? "clock"
                        : "plus"
                    Button {
                        createExtensionWorktreeWorkspace(for: section.treeSection)
                    } label: {
                        CmuxSystemSymbolImage(magnified: worktreeButtonSymbol, pointSize: 11, weight: .regular, tint: .primary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id))
                    .safeHelp(String(localized: "sidebar.extension.createWorktree", defaultValue: "Create worktree"))
                    .accessibilityIdentifier("ExtensionSidebarCreateWorktreeButton.\(section.id)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(section.rows) { row in
                        CmuxExtensionSidebarWorkspaceRowView(
                            row: row,
                            workspace: workspaceSnapshotsById[row.workspaceId],
                            providerId: providerId,
                            relativeNow: now,
                            isSelected: row.workspaceId == selectedWorkspaceId,
                            onSelect: selectExtensionSidebarWorkspace,
                            onOpenWindow: CmuxExtensionSidebarInspectorWindowController.show
                        )
                        .id(row.id)
                        .accessibilityIdentifier("extensionSidebar.workspace.\(row.workspaceId.uuidString)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func extensionWorkspaceSnapshot(for workspaceId: UUID) -> CmuxSidebarProviderWorkspace? {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        return extensionWorkspaceSnapshot(
            for: workspace,
            unreadSnapshot: sidebarUnread.snapshot
        )
    }

    private func extensionSidebarTreeSectionTitle(_ section: CmuxSidebarProviderTreeSection) -> String {
        if let titleText = section.titleText {
            return CmuxExtensionSidebarSelection.localizedText(titleText)
        }
        return section.title
    }

    private func selectExtensionSidebarWorkspace(_ workspaceId: UUID) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        selection = .tabs
        selectedTabIds = [workspaceId]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == workspaceId }
        tabManager.selectWorkspace(workspace)
    }

    private func createExtensionWorktreeWorkspace(for section: CmuxSidebarProviderTreeSection) {
        guard let projectRootPath = section.projectRootPath,
              !extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id) else {
            return
        }

        extensionSidebarWorktreeCreationInFlightSectionIds.insert(section.id)
        Task {
            do {
                let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRootPath)
                let spawnArgs = result.workspaceSpawnArgs()
                let workspace = tabManager.acquireOptionalWorkspaceIfActive {
                    tabManager.addWorkspaceIfActive(
                        title: spawnArgs.title,
                        titleSource: .auto,
                        workingDirectory: spawnArgs.workingDirectory,
                        initialTerminalInput: spawnArgs.initialTerminalInput,
                        inheritWorkingDirectory: spawnArgs.inheritWorkingDirectory,
                        select: true,
                        eagerLoadTerminal: false,
                        autoWelcomeIfNeeded: spawnArgs.initialTerminalInput == nil
                    )
                }
                if workspace == nil {
                    try await result.rollbackUnclaimedWorktree()
                }
            } catch {
                NSSound.beep()
#if DEBUG
                cmuxDebugLog("extensionSidebar.worktree.failed project=\(projectRootPath) error=\(error.localizedDescription)")
#endif
            }
            extensionSidebarWorktreeCreationInFlightSectionIds.remove(section.id)
        }
    }

    private func workspaceScrollContent(
        renderContext: WorkspaceListRenderContext,
        minHeight: CGFloat,
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> some View {
        let signpost = SidebarProfilingSignposts.begin("sidebar-scroll-content", "workspaces=\(renderContext.workspaceCount) renderItems=\(renderContext.workspaceRenderItems.count) minHeight=\(minHeight)"); defer { SidebarProfilingSignposts.end(signpost) }
        let shouldCollectWorkspaceDropTargets = SidebarDropPlanner().shouldCollectWorkspaceDropTargets(
            draggedTabId: dragState.draggedTabId,
            isBonsplitWorkspaceDropActive: isBonsplitWorkspaceDropTargetCollectionActive ||
                isWorkspaceReorderDropTargetCollectionActive
        )
        // Rows stay lazy + pinned top; `.frame(minHeight:)` fills the viewport
        // (#3241) or scrolls without measuring the LazyVStack. The prior
        // SidebarRowsFillLayout measured it (`sizeThatFits(height: nil)`) every
        // pass, realizing all rows and re-livelocking at scale (#2586 / #5764 /
        // #5845; regressed by #6033). Drop/tap = background; indicator on rows.
        let content = workspaceRows(
            renderContext: renderContext,
            shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets,
            unreadSnapshot: unreadSnapshot
        )
            .overlay(alignment: .bottom) {
                if emptyAreaTopDropIndicatorVisible() {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: tabRowSpacing / 2)
                }
            }
            // Neutralize ALL end-of-list empty-area interactions over the rows
            // block (2pt gaps, row padding, and the entire list when it
            // overflows) so none fall through to SidebarEmptyArea behind:
            // workspace-reorder drops, Bonsplit new-workspace drops, and the
            // double-tap-to-create gesture. Sized to the rows, so only the
            // genuine blank area below the last row stays interactive. This is
            // the measurement-free equivalent of physically placing the empty
            // area below the rows; doing that requires asking the LazyVStack for
            // its height, which realizes every row each layout pass and is the
            // livelock this change removes. The parent-owned AppKit overlays
            // render in front and own both workspace drop types.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {}
                    .onDrop(of: SidebarTabDragPayload.dropContentTypes, isTargeted: nil) { _ in false }
                    .onDrop(of: BonsplitTabDragPayload.dropContentTypes, isTargeted: nil) { _ in false }
            }
            .frame(minHeight: minHeight, alignment: .top)
            .background(alignment: .top) {
                SidebarEmptyArea(
                    rowSpacing: tabRowSpacing,
                    selection: $selection,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dragAutoScrollController: dragAutoScrollController,
                    topDropIndicatorVisible: false,
                    bonsplitDropIndicator: dropIndicatorBinding,
                    expandsVertically: true
                )
            }

        return rowsWithGatedDropTargetReader(
            rows: content,
            renderContext: renderContext,
            shouldCollect: shouldCollectWorkspaceDropTargets
        )
        .overlay {
            workspaceReorderDropOverlay(renderContext: renderContext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            bonsplitWorkspaceDropOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func workspaceRows(
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool,
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> some View {
        let signpost = SidebarProfilingSignposts.begin("sidebar-workspace-rows", "renderItems=\(renderContext.workspaceRenderItems.count) collectDropTargets=\(shouldCollectWorkspaceDropTargets)")
        let renderItems = renderContext.workspaceRenderItems
        // Reduce live models to cheap immutable values above the LazyVStack.
        // Shared notification/selection projections are built once here; full
        // row trees and row-specific closure binding remain lazy.
        let unreadSummariesByWorkspaceId = unreadSnapshot.summaryByWorkspaceId
        let notificationIndex = SidebarWorkspaceNotificationIndex(
            notifications: notificationStore.notifications
        )
        let workspaceRowInputsById = Dictionary(uniqueKeysWithValues: renderContext.tabs.map { workspace in
            (
                workspace.id,
                workspaceRowInput(
                    workspace,
                    renderContext: renderContext,
                    unreadSummariesByWorkspaceId: unreadSummariesByWorkspaceId
                )
            )
        })
        let _ = anchorCwdRevision
        let groupRowSnapshotsById = Dictionary(uniqueKeysWithValues: renderContext.workspaceGroups.map { group in
            (
                group.id,
                sidebarWorkspaceGroupRowSnapshot(
                    group: group,
                    memberWorkspaceIds: renderContext.memberWorkspaceIdsByGroupId[group.id] ?? [],
                    renderContext: renderContext,
                    unreadSnapshot: unreadSnapshot,
                    notificationIndex: notificationIndex,
                    shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
                )
            )
        })
        let listSnapshot = SidebarWorkspaceRowsSnapshot(
            workspaceRowsById: workspaceRowInputsById,
            groupRowsById: groupRowSnapshotsById,
            selectedContextTargetIds: renderContext.selectedContextTargetIds,
            anchorWorkspaceIds: Set(renderContext.workspaceGroups.compactMap(\.liveAnchorWorkspaceId)),
            workspaceGroupMenuSnapshot: renderContext.workspaceGroupMenuSnapshot,
            canCreateEmptyGroup: tabManager.selectedTab?.isRemoteTmuxMirror != true,
            notificationIndex: notificationIndex
        )
        let actionFactory = makeWorkspaceRowActionFactory()
        let rows = LazyVStack(spacing: tabRowSpacing) {
            ForEach(renderItems, id: \.id) { item in
                switch item {
                case .groupHeader(let groupId, _):
                    if let snapshot = listSnapshot.groupRowsById[groupId] {
                        sidebarWorkspaceGroupRow(snapshot: snapshot)
                    }
                case .workspace(let workspaceId):
                    if let input = listSnapshot.workspaceRowsById[workspaceId] {
                        workspaceRow(
                            input: input,
                            listSnapshot: listSnapshot,
                            actionFactory: actionFactory,
                            shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
                        )
                    }
                }
            }
        }
        .padding(.vertical, SidebarWorkspaceListMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No whole-content height measurement here: reading the LazyVStack's
        // total height (GeometryReader, or a custom Layout's sizeThatFits) fed a
        // non-converging relayout loop (#2586 / #5764 / #5845). Fill is handled
        // by `.frame(minHeight:)` in workspaceScrollContent.
        let _ = SidebarProfilingSignposts.end(signpost)
        rows
    }
    /// Conditionally installs the row-frame `overlayPreferenceValue` reader (the part
    /// that defeats `LazyVStack` virtualization) only while a drag is collecting drop
    /// targets. Kept separate from the always-mounted drop-capture overlay so the gate
    /// flip never changes the drop NSView's identity. (#5325 review)
    @ViewBuilder
    private func rowsWithGatedDropTargetReader<Rows: View>(
        rows: Rows,
        renderContext: WorkspaceListRenderContext,
        shouldCollect: Bool
    ) -> some View {
        if shouldCollect {
            rows
                .overlayPreferenceValue(SidebarWorkspaceRowFramePreferenceKey.self) { anchors in
                    GeometryReader { proxy in
                        let workspaceGroupsByAnchor = Dictionary(
                            uniqueKeysWithValues: renderContext.workspaceGroups.map { ($0.anchorWorkspaceId, $0) }
                        )
                        SidebarWorkspaceDropTargetWriters(
                            bonsplitTargetBridge: bonsplitWorkspaceDropTargetBridge,
                            bonsplitTargets: renderContext.tabs.compactMap { tab in
                                guard let anchor = anchors[tab.id] else { return nil }
                                return SidebarDropPlanner.WorkspaceDropTarget(
                                    workspaceId: tab.id,
                                    isPinned: tab.isPinned,
                                    frame: proxy[anchor]
                                )
                            },
                            reorderTargetBridge: workspaceReorderDropTargetBridge,
                            reorderTargets: renderContext.visibleWorkspaceRowIds.compactMap { workspaceId in
                                guard let anchor = anchors[workspaceId],
                                      renderContext.workspaceById[workspaceId] != nil
                                          || workspaceGroupsByAnchor[workspaceId] != nil else {
                                    return nil
                                }
                                let group = workspaceGroupsByAnchor[workspaceId]
                                let targetGroupId = group?.id ??
                                    (renderContext.workspaceGroupIdByWorkspaceId[workspaceId] ?? nil)
                                return SidebarWorkspaceReorderDropOverlay.Target(
                                    workspaceId: workspaceId,
                                    groupId: targetGroupId,
                                    isGroupHeader: group != nil,
                                    frame: proxy[anchor]
                                )
                            }
                        )
                    }
                }
        } else {
            rows
        }
    }

    private func bonsplitWorkspaceDropOverlay() -> some View {
        SidebarBonsplitTabWorkspaceDropOverlay(
            currentSelectedTabId: {
                tabManager.selectedTabId
            },
            sidebarIndexForTabId: { workspaceId in
                tabManager.tabs.firstIndex { $0.id == workspaceId }
            },
            moveToExistingWorkspace: { workspaceId, transfer in
                guard let app = AppDelegate.shared else {
                    return false
                }
                if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
                   source.workspaceId == workspaceId {
                    return true
                }
                return app.moveBonsplitTab(
                    tabId: transfer.tab.id,
                    toWorkspace: workspaceId,
                    focus: true,
                    focusWindow: true
                )
            },
            moveToNewWorkspace: { insertionIndex, transfer in
                guard let app = AppDelegate.shared,
                      let result = app.moveBonsplitTabToNewWorkspace(
                        tabId: transfer.tab.id,
                        destinationManager: tabManager,
                        focus: true,
                        focusWindow: true,
                        insertionIndexOverride: insertionIndex
                      ) else {
                    return nil
                }
                return result.destinationWorkspaceId
            },
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            dropIndicator: dropIndicatorBinding,
            updateAutoscroll: {
                dragAutoScrollController.updateFromDragLocation()
            },
            setWorkspaceDropTargetCollectionActive: { isActive in
                guard isBonsplitWorkspaceDropTargetCollectionActive != isActive else { return }
                isBonsplitWorkspaceDropTargetCollectionActive = isActive
            },
            isWorkspaceDropTargetCollectionActive: isBonsplitWorkspaceDropTargetCollectionActive,
            targetBridge: bonsplitWorkspaceDropTargetBridge
        )
    }

    private func workspaceReorderDropOverlay(
        renderContext: WorkspaceListRenderContext,
        pointOffset: CGSize = .zero
    ) -> some View {
        SidebarWorkspaceReorderDropOverlay(
            targetBridge: workspaceReorderDropTargetBridge,
            isValidDrag: {
                dragState.currentWorkspaceDragId != nil
            },
            updateDrag: { point, targets in
                updateWorkspaceReorderDrop(point: point, targets: targets, renderContext: renderContext)
            },
            performDrop: { point, targets in
                performWorkspaceReorderDrop(point: point, targets: targets, renderContext: renderContext)
            },
            performPendingDrop: { pendingDrop, targets in
                performWorkspaceReorderDrop(
                    point: pendingDrop.point,
                    targets: targets,
                    pasteboardWorkspaceId: pendingDrop.workspaceId,
                    pendingSessionId: pendingDrop.sessionId,
                    renderContext: renderContext
                )
            },
            clearDropIndicator: {
                dragState.clearDropIndicator()
                dragAutoScrollController.stop()
            },
            setWorkspaceDropTargetCollectionActive: { isActive in
                guard isWorkspaceReorderDropTargetCollectionActive != isActive else { return }
                isWorkspaceReorderDropTargetCollectionActive = isActive
            },
            hasLiveWorkspaceDrag: {
                hasLiveWorkspaceDragForCurrentPasteboard()
            },
            pointOffset: pointOffset
        )
    }

    /// A sidebar UTI can outlive its AppKit source. Only the tokenized value
    /// belonging to the registry's current session may arm the reorder overlay.
    private func hasLiveWorkspaceDragForCurrentPasteboard() -> Bool {
        dragState.acceptsLiveSidebarSessionForCurrentPasteboard()
    }

    private func activateSidebarWorkspaceDragIfNeeded(pasteboardWorkspaceId: UUID? = nil) -> Bool {
        // AppKit's retained source callback is the only authority that ends a
        // drag. Pasteboard data may confirm that live session's identity, but
        // residual data must never create one.
        guard let dragId = dragState.currentWorkspaceDragId else {
#if DEBUG
            cmuxDebugLog("sidebar.drag.activate rejected reason=noDragId")
#endif
            return false
        }
        if !dragState.acceptsLiveSidebarSessionForCurrentPasteboard() {
#if DEBUG
            cmuxDebugLog("sidebar.drag.activate rejected reason=sessionMismatch")
#endif
            return false
        }
        guard pasteboardWorkspaceId == nil || pasteboardWorkspaceId == dragId else {
#if DEBUG
            cmuxDebugLog("sidebar.drag.activate rejected reason=payloadMismatch")
#endif
            return false
        }
        if dragState.draggedTabId == dragId {
            return true
        }
        if tabManager.tabs.contains(where: { $0.id == dragId }) {
            // A source view can rebuild while AppKit keeps its drag alive. The
            // registry session preserves source ownership across that rebuild.
            let isSourceGroupAnchor = tabManager.workspaceGroups.contains {
                $0.anchorWorkspaceId == dragId
            }
            guard !SidebarWorkspaceDragActivationPolicy().shouldRejectMirroring(
                isLocalWorkspace: true,
                isSourceGroupAnchor: isSourceGroupAnchor
            ) else {
                return false
            }
            return dragState.activateDragging(tabId: dragId)
        }
        if tabManager.workspaceGroups.contains(where: { $0.id == dragId && $0.isEmpty }) {
            // A header-only group uses its group id as the stable drag
            // identity. It has no source workspace/TabManager lookup, but it
            // is still a local group-slot drag and must be re-armed here.
            return dragState.activateDragging(tabId: dragId)
        }
        guard let sourceManager = AppDelegate.shared?.tabManagerFor(tabId: dragId) else {
            return false
        }
        let isSourceGroupAnchor = sourceManager.workspaceGroups.contains {
            $0.liveAnchorWorkspaceId == dragId
        }
        guard !SidebarWorkspaceDragActivationPolicy().shouldRejectMirroring(
            isLocalWorkspace: false,
            isSourceGroupAnchor: isSourceGroupAnchor
        ) else {
            return false
        }
        guard dragState.activateDragging(tabId: dragId) else { return false }
        dragState.foreignDraggedIsPinned = sourceManager.tabs.first { $0.id == dragId }?.isPinned ?? false
        return true
    }

    private func updateWorkspaceReorderDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        renderContext: WorkspaceListRenderContext
    ) -> Bool {
        guard activateSidebarWorkspaceDragIfNeeded(),
              let plan = workspaceReorderPlan(point: point, targets: targets, renderContext: renderContext) else {
            dragState.clearDropIndicator()
            return false
        }
        dragAutoScrollController.updateFromDragLocation()
        guard dragState.dropIndicator != plan.indicator ||
                dragState.dropIndicatorScope != plan.indicatorScope else {
            return true
        }
        dragState.setDropIndicator(plan.indicator, scope: plan.indicatorScope)
        return true
    }

    /// AppKit-table variant of `updateWorkspaceReorderDrop` that never writes
    /// the indicator into `dragState`: the table controller paints the two
    /// affected cells directly, so a dragState write here would only rebuild
    /// every sidebar row per gap change (the indicator-lags-pointer report).
    private func updateWorkspaceReorderDropForTable(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        pasteboardWorkspaceId: UUID?,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableReorderDropUpdate? {
        guard activateSidebarWorkspaceDragIfNeeded(pasteboardWorkspaceId: pasteboardWorkspaceId),
              let draggedWorkspaceId = dragState.draggedTabId,
              let plan = workspaceReorderPlan(point: point, targets: targets, renderContext: renderContext) else {
            return nil
        }
        dragAutoScrollController.updateFromDragLocation()
        return SidebarWorkspaceTableReorderDropUpdate(
            indicator: plan.indicator,
            scope: plan.indicatorScope,
            draggedWorkspaceId: draggedWorkspaceId,
            indicatorRowIds: sidebarDropIndicatorRowIds(
                draggedWorkspaceId: draggedWorkspaceId,
                scope: plan.indicatorScope,
                tabs: renderContext.tabs,
                workspaceGroups: renderContext.workspaceGroups,
                visibleWorkspaceRowIds: renderContext.visibleWorkspaceRowIds
            ),
            plan: plan
        )
    }

    private func performWorkspaceReorderDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        pasteboardWorkspaceId: UUID? = nil,
        pendingSessionId: UUID? = nil,
        renderContext: WorkspaceListRenderContext
    ) -> Bool {
        var ownsPresentationCleanup = false
        defer {
            // Only a drop that passed its session/plan validation owns this
            // presentation cleanup. A stale deferred callback must not dismiss
            // or stop autoscroll for a newer drag.
            if ownsPresentationCleanup {
                dragState.dismissPresentation()
                dragAutoScrollController.stop()
            }
        }
        let plan: SidebarWorkspaceReorderDropPlan?
        if let pendingSessionId {
            guard let draggedWorkspaceId = pasteboardWorkspaceId,
                  canCommitPendingWorkspaceDrop(
                      workspaceId: draggedWorkspaceId,
                      sessionId: pendingSessionId
                  ) else {
                return false
            }
            ownsPresentationCleanup = true
            plan = workspaceReorderPlan(
                point: point,
                targets: targets,
                renderContext: renderContext,
                draggedWorkspaceId: draggedWorkspaceId
            )
        } else {
            guard activateSidebarWorkspaceDragIfNeeded(pasteboardWorkspaceId: pasteboardWorkspaceId) else {
                return false
            }
            ownsPresentationCleanup = true
            plan = workspaceReorderPlan(point: point, targets: targets, renderContext: renderContext)
        }
        guard let plan else { return false }
        return performWorkspaceReorderPlan(plan)
    }

    /// Accepts a deferred drop only while its generation is still current or
    /// has already completed. A newer native drag must never inherit an older
    /// pending drop's workspace identity.
    private func canCommitPendingWorkspaceDrop(
        workspaceId: UUID,
        sessionId: UUID
    ) -> Bool {
        dragState.acceptsWorkspaceDragSession(
            sessionId: sessionId,
            workspaceId: workspaceId
        )
    }

    private func workspaceReorderPlan(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        renderContext: WorkspaceListRenderContext,
        draggedWorkspaceId explicitDraggedWorkspaceId: UUID? = nil
    ) -> SidebarWorkspaceReorderDropPlan? {
        guard let draggedTabId = explicitDraggedWorkspaceId ?? dragState.draggedTabId else { return nil }
        let foreignDraggedIsPinned = dragState.foreignDraggedIsPinned
            ?? resolvedDraggedWorkspacePinState(for: draggedTabId)
        let draggedBlockIds = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
            orderedWorkspaceIds: renderContext.tabs.map(\.id),
            selectedIds: selectedTabIds,
            draggedId: draggedTabId,
            anchorIds: Set(renderContext.workspaceGroups.map(\.anchorWorkspaceId))
        )
        return SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: draggedTabId,
                foreignDraggedIsPinned: foreignDraggedIsPinned,
                workspaces: renderContext.tabs.map {
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: $0.id,
                        isPinned: $0.isPinned,
                        groupId: $0.groupId
                    )
                },
                groups: renderContext.workspaceGroups.map {
                        SidebarWorkspaceReorderGroupSnapshot(
                            id: $0.id,
                            anchorWorkspaceId: $0.anchorWorkspaceId,
                            isPinned: $0.isPinned,
                            isEmpty: $0.isEmpty
                        )
                },
                targets: targets.map {
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: $0.workspaceId,
                        groupId: $0.groupId,
                        isGroupHeader: $0.isGroupHeader,
                        frame: $0.frame
                    )
                },
                draggedBlockWorkspaceIds: Set(draggedBlockIds)
            )
        )
    }

    /// Resolves the frozen pin tier needed by a deferred cross-window drop.
    private func resolvedDraggedWorkspacePinState(for workspaceId: UUID) -> Bool? {
        if let localWorkspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
            return localWorkspace.isPinned
        }
        return AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.tabs
            .first { $0.id == workspaceId }?.isPinned
    }

    private func performWorkspaceReorderPlan(_ plan: SidebarWorkspaceReorderDropPlan) -> Bool {
        switch plan.action {
        case .reorderGroup(let targetIndex):
            let groupId = plan.draggedWorkspaceId
            guard tabManager.workspaceGroups.contains(where: { $0.id == groupId }) else {
                return false
            }
            let previousOrder = tabManager.workspaceGroups.map(\.id)
            tabManager.moveWorkspaceGroup(groupId: groupId, toIndex: targetIndex)
            let changed = tabManager.workspaceGroups.map(\.id) != previousOrder
            // A self-drop is a handled no-op; returning false makes AppKit
            // animate the header back even though the pointer landed on its
            // own row.
            return changed || previousOrder.firstIndex(of: groupId).map { targetIndex == $0 } == true
        case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId):
            let selectionBeforeReorder = selectedTabIds
            let anchorWorkspaceIdBeforeReorder = SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
                existingAnchorIndex: lastSidebarSelectionIndex,
                liveWorkspaceIds: tabManager.tabs.map(\.id)
            )
            let movingIds = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
                orderedWorkspaceIds: tabManager.tabs.map(\.id),
                selectedIds: selectedTabIds,
                draggedId: plan.draggedWorkspaceId,
                anchorIds: Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
            )
            let didReorder: Bool
            if movingIds.count > 1 {
                didReorder = tabManager.reorderSidebarWorkspaces(
                    tabIds: movingIds,
                    draggedTabId: plan.draggedWorkspaceId,
                    toIndex: targetIndex,
                    isDragOperation: true,
                    usesTopLevelRows: usesTopLevelRows,
                    explicitGroupId: explicitGroupId
                )
            } else {
                didReorder = tabManager.reorderSidebarWorkspace(
                    tabId: plan.draggedWorkspaceId,
                    toIndex: targetIndex,
                    isDragOperation: true,
                    usesTopLevelRows: usesTopLevelRows,
                    explicitGroupId: explicitGroupId
                )
            }
            syncSidebarSelectionAfterWorkspaceReorder(
                preserving: selectionBeforeReorder,
                preferredAnchorWorkspaceId: anchorWorkspaceIdBeforeReorder
            )
            return didReorder
        case .crossWindow(insertionIndex: _, proposedInsertionIndex: let proposedInsertionIndex):
            return performCrossWindowWorkspaceDrop(plan: plan, proposedInsertionIndex: proposedInsertionIndex)
        }
    }

    private func performCrossWindowWorkspaceDrop(
        plan: SidebarWorkspaceReorderDropPlan,
        proposedInsertionIndex: Int
    ) -> Bool {
        guard let app = AppDelegate.shared,
              let destinationWindowId = app.windowId(for: tabManager),
              let sourceManager = app.tabManagerFor(tabId: plan.draggedWorkspaceId),
              !sourceManager.workspaceGroups.contains(where: { $0.liveAnchorWorkspaceId == plan.draggedWorkspaceId }) else {
            return false
        }

        let movingIds = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
            orderedWorkspaceIds: sourceManager.tabs.map(\.id),
            selectedIds: sourceManager.sidebarSelectedWorkspaceIds,
            draggedId: plan.draggedWorkspaceId,
            anchorIds: Set(sourceManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
        )
        guard !movingIds.isEmpty else { return false }

        let pinStateById = Dictionary(uniqueKeysWithValues: movingIds.map { id in
            (id, sourceManager.tabs.first { $0.id == id }?.isPinned ?? false)
        })
        var movedIds: [UUID] = []
        for isPinnedTier in [false, true] {
            let tierIds = movingIds.filter { (pinStateById[$0] ?? false) == isPinnedTier }
            guard !tierIds.isEmpty else { continue }
            let topLevelIds = crossWindowTopLevelWorkspaceIds()
            let slot = clampedCrossWindowTopLevelSlot(
                proposedInsertionIndex,
                draggedIsPinned: isPinnedTier,
                topLevelIds: topLevelIds,
                pinnedTopLevelIds: crossWindowTopLevelPinnedWorkspaceIds()
            )
            let base = crossWindowRawInsertIndex(forTopLevelSlot: slot, topLevelIds: topLevelIds)
            var tierOffset = 0
            for workspaceId in tierIds {
                if app.moveWorkspaceToWindow(
                    workspaceId: workspaceId,
                    windowId: destinationWindowId,
                    atIndex: base + tierOffset,
                    focus: false
                ) {
                    movedIds.append(workspaceId)
                    tierOffset += 1
                }
            }
        }

        guard !movedIds.isEmpty else { return false }
        let focusId = movedIds.contains(plan.draggedWorkspaceId) ? plan.draggedWorkspaceId : (movedIds.last ?? plan.draggedWorkspaceId)
        _ = app.moveWorkspaceToWindow(workspaceId: focusId, windowId: destinationWindowId, focus: true)
        selectedTabIds = Set(movedIds)
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
        return true
    }

    private func clampedCrossWindowTopLevelSlot(
        _ proposedSlot: Int,
        draggedIsPinned: Bool,
        topLevelIds: [UUID],
        pinnedTopLevelIds: Set<UUID>
    ) -> Int {
        let clampedSlot = max(0, min(proposedSlot, topLevelIds.count))
        let pinnedCount = topLevelIds.reduce(into: 0) { count, workspaceId in
            if pinnedTopLevelIds.contains(workspaceId) {
                count += 1
            }
        }
        return draggedIsPinned ? min(clampedSlot, pinnedCount) : max(clampedSlot, pinnedCount)
    }

    private func crossWindowTopLevelWorkspaceIds() -> [UUID] {
        tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowTopLevelPinnedWorkspaceIds() -> Set<UUID> {
        tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowRawInsertIndex(forTopLevelSlot slot: Int, topLevelIds: [UUID]) -> Int {
        guard slot < topLevelIds.count else { return tabManager.tabs.count }
        let topLevelId = topLevelIds[slot]
        if let liveIndex = tabManager.tabs.firstIndex(where: { $0.id == topLevelId }) {
            return liveIndex
        }
        // Empty group headers occupy visual top-level slots but have no tab
        // row. Attach immediately before the next live slot so cross-window
        // insertion does not silently jump to the end.
        for nextId in topLevelIds.dropFirst(slot + 1) {
            if let nextIndex = tabManager.tabs.firstIndex(where: { $0.id == nextId }) {
                return nextIndex
            }
        }
        return tabManager.tabs.count
    }

    private func syncSidebarSelectionAfterWorkspaceReorder(
        preserving previousSelectionIds: Set<UUID>,
        preferredAnchorWorkspaceId: UUID?
    ) {
        let liveWorkspaceIds = tabManager.tabs.map(\.id)
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: previousSelectionIds,
            liveWorkspaceIds: liveWorkspaceIds,
            fallbackSelectedWorkspaceId: tabManager.selectedTabId
        )
        selectedTabIds = nextSelectionIds
        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId,
            selectedWorkspaceIds: nextSelectionIds,
            focusedWorkspaceId: tabManager.selectedTabId,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }

    private func selectWorkspaceRow(
        _ workspace: Workspace,
        index: Int,
        modifiers: NSEvent.ModifierFlags
    ) {
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == workspace.id
#if DEBUG
        var modifierDescription = ""
        if isCommand { modifierDescription += "cmd " }
        if isShift { modifierDescription += "shift " }
        if modifiers.contains(.option) { modifierDescription += "opt " }
        if modifiers.contains(.control) { modifierDescription += "ctrl " }
        cmuxDebugLog(
            "sidebar.select workspace=\(workspace.id.uuidString.prefix(5)) modifiers=" +
            (modifierDescription.isEmpty
                ? "none"
                : modifierDescription.trimmingCharacters(in: .whitespaces))
        )
#endif

        let workspaceIds = tabManager.tabs.map(\.id)
        let anchorIds = Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
        let selectionKindPolicy = SidebarSelectionKindPolicy()
        let shiftAnchorIndex = isShift
            ? SidebarWorkspaceSelectionSyncPolicy().shiftClickAnchorIndex(
                existingAnchorIndex: lastSidebarSelectionIndex,
                selectedWorkspaceIds: selectedTabIds,
                focusedWorkspaceId: tabManager.selectedTabId,
                liveWorkspaceIds: workspaceIds
            )
            : nil

        if isShift, let anchorIndex = shiftAnchorIndex {
            let lower = min(anchorIndex, index)
            let upper = max(anchorIndex, index)
            let collapsedGroupIds = Set(
                tabManager.workspaceGroups.filter(\.isCollapsed).map(\.id)
            )
            let anchorIdsByGroup = Dictionary(
                uniqueKeysWithValues: tabManager.workspaceGroups.compactMap { group in
                    group.liveAnchorWorkspaceId.map { (group.id, $0) }
                }
            )
            let visibleRangeIds = tabManager.tabs[lower...upper].compactMap { candidate -> UUID? in
                if let groupId = candidate.groupId,
                   collapsedGroupIds.contains(groupId),
                   anchorIdsByGroup[groupId] != candidate.id {
                    return nil
                }
                return candidate.id
            }
            selectedTabIds = Set(selectionKindPolicy.workspaceShiftRangeIds(
                rangeIds: Array(selectedTabIds),
                anchorIds: anchorIds
            ))
            let rangeIds = selectionKindPolicy.workspaceShiftRangeIds(
                rangeIds: visibleRangeIds,
                anchorIds: anchorIds
            )
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            selectedTabIds = selectionKindPolicy.workspaceCmdClickSelection(
                current: selectedTabIds,
                clickedId: workspace.id,
                anchorIds: anchorIds
            )
        } else {
            selectedTabIds = [workspace.id]
        }

        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceClick(
            isShiftClick: isShift,
            resolvedShiftAnchorIndex: shiftAnchorIndex,
            clickedIndex: index
        )
        tabManager.selectTab(workspace)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: workspace.id,
                surfaceId: tabManager.focusedSurfaceId(for: workspace.id)
            )
        }
        selection = .tabs
    }

    private func syncWorkspaceRowSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map(\.id))
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }

    private func moveWorkspaceRow(_ workspace: Workspace, by delta: Int) {
        guard tabManager.reorderWorkspace(tabId: workspace.id, by: delta) else { return }
        selectedTabIds = [workspace.id]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == workspace.id }
        tabManager.selectTab(workspace)
        selection = .tabs
    }

    private func closeWorkspaceRows(_ workspaceIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
        syncWorkspaceRowSelectionAfterMutation()
    }

    private func moveWorkspaceRows(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared else { return }
        let orderedIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedIds.isEmpty else { return }
        var movedIds: [UUID] = []
        movedIds.reserveCapacity(orderedIds.count)
        for workspaceId in orderedIds {
            if app.moveWorkspaceToWindow(
                workspaceId: workspaceId,
                windowId: windowId,
                focus: false
            ) {
                movedIds.append(workspaceId)
            }
        }
        guard let focusId = movedIds.last else { return }
        // The workspace is already attached to the destination, so this takes
        // AppDelegate's same-manager focus path rather than moving it twice.
        _ = app.moveWorkspaceToWindow(workspaceId: focusId, windowId: windowId, focus: true)
        selectedTabIds.subtract(movedIds)
        syncWorkspaceRowSelectionAfterMutation()
    }

    private func moveWorkspaceRowsToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared else { return }
        let orderedIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstId = orderedIds.first else { return }
        guard let newWindowId = app.moveWorkspaceToNewWindow(
            workspaceId: firstId,
            focus: false
        ) else { return }
        var movedIds = [firstId]
        movedIds.reserveCapacity(orderedIds.count)
        if orderedIds.count > 1 {
            for workspaceId in orderedIds.dropFirst() {
                if app.moveWorkspaceToWindow(
                    workspaceId: workspaceId,
                    windowId: newWindowId,
                    focus: false
                ) {
                    movedIds.append(workspaceId)
                }
            }
        }
        // Focus the final successful attachment without detaching or attaching
        // it again; AppDelegate recognizes it is already in this window.
        if let focusId = movedIds.last {
            _ = app.moveWorkspaceToWindow(workspaceId: focusId, windowId: newWindowId, focus: true)
        }
        selectedTabIds.subtract(movedIds)
        syncWorkspaceRowSelectionAfterMutation()
    }

    private func openWorkspaceRowPullRequest(
        _ url: URL,
        workspace: Workspace,
        index: Int,
        opensInCmuxBrowser: Bool
    ) {
        selectWorkspaceRow(workspace, index: index, modifiers: NSEvent.modifierFlags)
        if opensInCmuxBrowser,
           tabManager.openBrowser(
               inWorkspace: workspace.id,
               url: url,
               preferSplitRight: true,
               insertAtEnd: true
           ) != nil {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openWorkspaceRowPort(
        _ port: Int,
        workspace: Workspace,
        index: Int,
        opensInCmuxBrowser: Bool
    ) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        openWorkspaceRowPullRequest(
            url,
            workspace: workspace,
            index: index,
            opensInCmuxBrowser: opensInCmuxBrowser
        )
    }

    private func workspaceRowInput(
        _ tab: Workspace,
        renderContext: WorkspaceListRenderContext,
        unreadSummariesByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary]
    ) -> SidebarWorkspaceRowInput {
#if DEBUG
        sidebarLazyContractProbe.workspaceRowInputProjection?()
#endif
        let signpost = SidebarProfilingSignposts.begin("sidebar-workspace-row", "index=\(renderContext.tabIndexById[tab.id] ?? -1) workspace=\(sidebarShortTabId(tab.id)) selected=\(tabManager.selectedTabId == tab.id)")
        defer { SidebarProfilingSignposts.end(signpost) }
        let index = renderContext.tabIndexById[tab.id] ?? 0
        let usesSelectedContextMenuTargets = selectedTabIds.contains(tab.id)
        let contextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedContextTargetIds
            : [tab.id]
        let contextMenuPinTarget = WorkspaceActionDispatcher.Target(
            workspaceIds: contextMenuWorkspaceIds,
            anchorWorkspaceId: tab.id
        )
        let contextMenuPinState = WorkspaceActionDispatcher.pinState(
            in: renderContext.pinResolutionContext,
            target: contextMenuPinTarget
        )
        let unreadSummary = unreadSummariesByWorkspaceId[tab.id]
            ?? SidebarWorkspaceUnreadSummary(unreadCount: 0, latestNotificationText: nil)
        let liveLatestNotificationText: String? = renderContext.tabItemSettings.showsNotificationMessage
            ? unreadSummary.latestNotificationText
            : nil
        let liveShowsModifierShortcutHints = showModifierHoldHints && modifierKeyMonitor.isModifierPressed
        let resolvedShowsModifierShortcutHints = SidebarShortcutHintFreezePolicy().resolved(
            live: liveShowsModifierShortcutHints,
            currentTabId: tab.id,
            frozenTabId: frozenShortcutHintsTabId,
            frozenValue: frozenShortcutHintsValue
        )
        let isPointerHovering = pointerInteractionMonitor.hoveredRowId == .workspace(tab.id)

        // Per-row drag snapshots. Reading `dragState` here in the parent
        // is intentional: the parent owns the @Observable store, and these
        // value snapshots are what get passed to the row. The row's
        // Equatable conformance ignores closures, so rows whose snapshot is
        // unchanged skip re-render when drag state moves.
        let isBeingDragged = dragState.draggedTabId == tab.id
        let sidebarReorderIds = renderContext.sidebarReorderIds
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: tab.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: tab.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: sidebarReorderIds,
            indicatorScope: dragState.dropIndicatorScope
        )
        let settings = renderContext.tabItemSettings
        let expectedPresentationKey = SidebarWorkspaceSnapshotFactory.presentationKey(
            settings: settings,
            showsAgentActivity: renderContext.showsAgentActivity
        )
        let cachedWorkspaceSnapshot = featureFlags.isAppKitSidebarListEnabled
            ? appKitRowSnapshotCache.value(for: tab.id)
            : workspaceSnapshotsById[tab.id]
        let workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
        if let cachedWorkspaceSnapshot,
           cachedWorkspaceSnapshot.presentationKey == expectedPresentationKey {
            workspaceSnapshot = cachedWorkspaceSnapshot
        } else {
            workspaceSnapshot = makeWorkspaceSnapshot(
                workspace: tab,
                settings: settings,
                showsAgentActivity: renderContext.showsAgentActivity
            )
            if featureFlags.isAppKitSidebarListEnabled {
                appKitRowSnapshotCache.store(workspaceSnapshot, for: tab.id)
            }
        }

        let result = SidebarWorkspaceRowInput(
            workspaceId: tab.id,
            groupId: renderContext.workspaceGroupIdByWorkspaceId[tab.id] ?? nil,
            index: index,
            workspaceCount: renderContext.workspaceCount,
            workspace: workspaceSnapshot,
            isActive: tabManager.selectedTabId == tab.id,
            isMultiSelected: selectedTabIds.contains(tab.id),
            hasUserCustomTitle: tab.effectiveCustomTitleSource == .user,
            hasCustomTitle: tab.hasCustomTitle,
            hasCustomDescription: tab.hasCustomDescription,
            customTitle: tab.customTitle,
            workspaceShortcutDigit: renderContext.numberedWorkspaceIndexById[tab.id].flatMap {
                WorkspaceShortcutMapper.digitForWorkspace(
                    at: $0,
                    workspaceCount: renderContext.numberedWorkspaceIndexById.count
                )
            },
            workspaceShortcutModifierSymbol: renderContext.workspaceNumberShortcut.numberedDigitHintPrefix,
            canCloseWorkspace: renderContext.canCloseWorkspace,
            unreadCount: unreadSummary.unreadCount,
            latestNotificationText: liveLatestNotificationText,
            showsAgentActivity: renderContext.showsAgentActivity,
            rowSpacing: tabRowSpacing,
            showsModifierShortcutHints: resolvedShowsModifierShortcutHints,
            isPointerHovering: isPointerHovering,
            isBeingDragged: isBeingDragged,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible,
            settings: settings,
            isChecklistExpanded: expandedChecklistWorkspaceIds.contains(tab.id),
            checklistAddFieldActivationToken: checklistAddFieldActivationTokens[tab.id] ?? 0,
            isChecklistPopoverPresented: checklistPopoverWorkspaceId == tab.id,
            isRemoteContextMenuEligible: tab.isRemoteWorkspace && !tab.isManagedCloudVMWorkspace,
            remoteConnectionState: tab.remoteConnectionState,
            contextMenuPinState: contextMenuPinState,
            inferredTaskStatus: workspaceSnapshot.taskStatusInput.inferred,
            activeTodoOverride: workspaceSnapshot.taskStatusInput.activeOverride,
            isTodoStatusHidden: workspaceSnapshot.taskStatusInput.isHidden
        )
        return result
    }

    /// Captures the parent action surface once per list evaluation. Invoking
    /// this factory below `LazyVStack` only binds immutable ids/values into
    /// closures; live models are resolved later when the user performs an
    /// action, never while SwiftUI realizes or lays out a row.
    private func makeWorkspaceRowActionFactory() -> SidebarWorkspaceRowActionFactory {
        let pointerInteractionMonitor = pointerInteractionMonitor
        return { input in
        let tabId = input.workspaceId
        let index = input.index
        let settings = input.settings
        let rowId = SidebarWorkspaceRenderItemID.workspace(tabId)
        let workspace: @MainActor () -> Workspace? = {
            tabManager.tabs.first { $0.id == tabId }
        }
        let checklistActions = SidebarWorkspaceChecklistActions(
            setItemState: { itemId, state in
                guard let tab = workspace() else { return }
                WorkspaceTodoActions.setChecklistItemState(id: itemId, state: state, in: tab)
            },
            removeItem: { itemId in
                guard let tab = workspace() else { return }
                WorkspaceTodoActions.removeChecklistItem(id: itemId, from: tab)
            },
            addItem: { text in
                guard let tab = workspace() else { return }
                WorkspaceTodoActions.addChecklistItem(text: text, to: tab)
            },
            editItem: { itemId, text in
                guard let tab = workspace() else { return }
                WorkspaceTodoActions.editChecklistItem(id: itemId, text: text, in: tab)
            },
            moveItem: { itemId, toIndex in
                guard let tab = workspace() else { return }
                WorkspaceTodoActions.moveChecklistItem(id: itemId, toIndex: toIndex, in: tab)
            },
            openPane: {
                guard let tab = workspace() else { return }
                WorkspaceTodoActions.openTodoPane(for: tab)
            },
            addAttachments: { itemId in
                guard let tab = workspace() else { return }
                WorkspaceTodoActions.addImageAttachments(to: itemId, in: tab)
            },
            removeAttachment: { itemId, attachmentId in
                guard let tab = workspace() else { return }
                WorkspaceTodoActions.removeImageAttachment(itemId: itemId, attachmentId: attachmentId, from: tab)
            },
            openAttachments: { itemId, selectedAttachmentId in
                guard let tab = workspace(),
                      let item = tab.todoState.checklist.first(where: { $0.id == itemId }) else {
                    return
                }
                WorkspaceTodoActions.openImageAttachments(
                    item.attachments,
                    selectedAttachmentId: selectedAttachmentId
                )
            }
        )
        return SidebarWorkspaceRowActions(
            select: { modifiers in
                guard let tab = workspace() else { return }
                selectWorkspaceRow(tab, index: index, modifiers: modifiers)
            },
            setCustomTitle: { title in
                tabManager.setCustomTitle(tabId: tabId, title: title)
            },
            clearCustomTitle: {
                tabManager.clearCustomTitle(tabId: tabId)
            },
            clearCustomDescription: {
                tabManager.clearCustomDescription(tabId: tabId)
            },
            editDescription: {
                guard let tab = workspace() else { return }
                selectedTabIds = [tabId]
                lastSidebarSelectionIndex = index
                tabManager.selectTab(tab)
                selection = .tabs
                _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
            },
            closeWorkspace: {
                guard let tab = workspace() else { return }
                tabManager.closeWorkspaceFromTabCloseButton(tab)
            },
            moveBy: { delta in
                guard let tab = workspace() else { return }
                moveWorkspaceRow(tab, by: delta)
            },
            moveTargetsToTop: { targetIds in
                tabManager.moveTabsToTop(Set(targetIds))
                syncWorkspaceRowSelectionAfterMutation()
            },
            currentWindowMoveTargets: {
                let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
                return AppDelegate.shared?
                    .windowMoveTargets(referenceWindowId: referenceWindowId)
                    .map {
                        SidebarWorkspaceWindowMoveTarget(
                            windowId: $0.windowId,
                            label: $0.label,
                            isCurrentWindow: $0.isCurrentWindow
                        )
                    } ?? []
            },
            moveTargetsToWindow: { targetIds, windowId in
                moveWorkspaceRows(targetIds, toWindow: windowId)
            },
            moveTargetsToNewWindow: { targetIds in
                moveWorkspaceRowsToNewWindow(targetIds)
            },
            closeTargets: { targetIds, allowPinned in
                closeWorkspaceRows(targetIds, allowPinned: allowPinned)
            },
            closeOtherTargets: { targetIds in
                let keepIds = Set(targetIds)
                let idsToClose = tabManager.tabs.compactMap {
                    keepIds.contains($0.id) ? nil : $0.id
                }
                closeWorkspaceRows(idsToClose, allowPinned: true)
            },
            closeTargetsBelow: {
                guard let anchorIndex = tabManager.tabs.firstIndex(
                    where: { $0.id == tabId }
                ) else { return }
                closeWorkspaceRows(
                    Array(tabManager.tabs.suffix(from: anchorIndex + 1).map(\.id)),
                    allowPinned: true
                )
            },
            closeTargetsAbove: {
                guard let anchorIndex = tabManager.tabs.firstIndex(
                    where: { $0.id == tabId }
                ) else { return }
                closeWorkspaceRows(
                    Array(tabManager.tabs.prefix(upTo: anchorIndex).map(\.id)),
                    allowPinned: true
                )
            },
            performPin: {
                guard let contextMenuPinState = input.contextMenuPinState else {
                    NSSound.beep()
                    return
                }
                _ = WorkspaceActionDispatcher.performPinAction(
                    contextMenuPinState,
                    in: tabManager
                )
                syncWorkspaceRowSelectionAfterMutation()
            },
            createEmptyGroup: {
                _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
            },
            createGroup: { workspaceIds in
                guard !workspaceIds.isEmpty else { return }
                tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: workspaceIds)
            },
            addTargetsToGroup: { workspaceIds, groupId in
                for workspaceId in workspaceIds {
                    tabManager.addWorkspaceToGroup(
                        workspaceId: workspaceId,
                        groupId: groupId
                    )
                }
            },
            removeTargetsFromGroup: { workspaceIds in
                for workspaceId in workspaceIds {
                    tabManager.removeWorkspaceFromGroup(workspaceId: workspaceId)
                }
            },
            reconnectTargets: { workspaceIds in
                for workspaceId in workspaceIds {
                    tabManager.tabs.first { $0.id == workspaceId }?
                        .reconnectRemoteConnection()
                }
            },
            disconnectTargets: { workspaceIds in
                for workspaceId in workspaceIds {
                    tabManager.tabs.first { $0.id == workspaceId }?
                        .disconnectRemoteConnection(clearConfiguration: false)
                }
            },
            applyColor: { hex, workspaceIds in
                tabManager.applyWorkspaceColor(hex, toWorkspaceIds: workspaceIds)
            },
            applyTodoStatus: { status, workspaceIds in
                let workspaces = workspaceIds.compactMap { workspaceId in
                    tabManager.tabs.first { $0.id == workspaceId }
                }
                WorkspaceTodoActions.applyStatusOverride(status, to: workspaces)
            },
            hideTodoStatus: { workspaceIds in
                let workspaces = workspaceIds.compactMap { workspaceId in
                    tabManager.tabs.first { $0.id == workspaceId }
                }
                WorkspaceTodoActions.hideStatus(for: workspaces)
            },
            requestChecklistAdd: {
                WorkspaceTodoActions.requestChecklistAddField(workspaceId: tabId)
            },
            markRead: { workspaceIds in
                for workspaceId in workspaceIds where
                    notificationStore.canMarkWorkspaceRead(forTabIds: [workspaceId]) {
                    notificationStore.markRead(forTabId: workspaceId)
                }
            },
            markUnread: { workspaceIds in
                for workspaceId in workspaceIds where
                    notificationStore.canMarkWorkspaceUnread(forTabIds: [workspaceId]) {
                    notificationStore.markUnread(forTabId: workspaceId)
                }
            },
            clearLatestNotifications: { workspaceIds in
                for workspaceId in workspaceIds {
                    notificationStore.clearLatestNotification(forTabId: workspaceId)
                }
            },
            currentNotificationsMuted: { workspaceIds in
                notificationStore.allWorkspaceNotificationsMuted(forTabIds: workspaceIds)
            },
            setNotificationsMuted: { workspaceIds, muted in
                _ = notificationStore.setWorkspaceNotificationsMuted(
                    muted,
                    forTabIds: workspaceIds
                )
            },
            openNotification: { notification in
                if AppDelegate.shared?.openTerminalNotification(notification) != true {
                    NSSound.beep()
                }
            },
            copyWorkspaceLinks: { workspaceIds in
                WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceLinks(
                    workspaceIds,
                    resolvingStableIdsFrom: tabManager.tabs
                )
            },
            openPullRequest: { url in
                guard let tab = workspace() else { return }
                openWorkspaceRowPullRequest(
                    url,
                    workspace: tab,
                    index: index,
                    opensInCmuxBrowser: settings.openPullRequestLinksInCmuxBrowser
                )
            },
            openPort: { port in
                guard let tab = workspace() else { return }
                openWorkspaceRowPort(
                    port,
                    workspace: tab,
                    index: index,
                    opensInCmuxBrowser: settings.openPortLinksInCmuxBrowser
                )
            },
            checklist: checklistActions,
            onToggleChecklistExpansion: {
                if expandedChecklistWorkspaceIds.contains(tabId) {
                    expandedChecklistWorkspaceIds.remove(tabId)
                } else {
                    expandedChecklistWorkspaceIds.insert(tabId)
                }
            },
            onConsumeChecklistAddFieldActivation: {
                checklistAddFieldActivationTokens[tabId] = nil
            },
            onChecklistPopoverPresentedChange: { presented in
                if presented {
                    checklistPopoverWorkspaceId = tabId
                } else if checklistPopoverWorkspaceId == tabId {
                    checklistPopoverWorkspaceId = nil
                }
            },
            onContextMenuAppear: {
                frozenShortcutHintsTabId = tabId
                frozenShortcutHintsValue = input.showsModifierShortcutHints
            },
            onContextMenuDisappear: {
                if frozenShortcutHintsTabId == tabId {
                    frozenShortcutHintsTabId = nil
                }
            },
            onPointerFrameChange: { [pointerInteractionMonitor] frame in
                pointerInteractionMonitor.updateFrame(
                    frame,
                    for: rowId,
                    workspaceId: tabId
                )
            },
            onPointerFrameDisappear: { [pointerInteractionMonitor] in
                pointerInteractionMonitor.removeFrame(for: rowId)
            },
            onPointerDragEligibilityChange: { [pointerInteractionMonitor] isEnabled in
                pointerInteractionMonitor.setWorkspaceDragEnabled(isEnabled, for: rowId)
            }
        )
        }
    }

    private func workspaceRow(
        input: SidebarWorkspaceRowInput,
        listSnapshot: SidebarWorkspaceRowsSnapshot,
        actionFactory: SidebarWorkspaceRowActionFactory,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> SidebarWorkspaceRowView {
        SidebarWorkspaceRowView(
            snapshot: input.rowSnapshot(list: listSnapshot),
            actions: actionFactory(input),
            shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
        )
    }

}

struct SidebarWorkspaceFrameAnchorModifier: ViewModifier {
    let id: UUID
    let isEnabled: Bool

    func body(content: Content) -> some View {
        // Branchless: always apply anchorPreference, emit [:] when disabled. An
        // if/else gives `content` distinct identity per state, so flipping
        // isEnabled at drag start/end recreated every visible row's subtree
        // (lost @State, fresh snapshot builds + relayout mid-drag). The frame
        // *reader* stays gated on the drag (#5325), so an empty emit costs nothing.
        content.anchorPreference(key: SidebarWorkspaceRowFramePreferenceKey.self, value: .bounds) { anchor in
            isEnabled ? [id: anchor] : [:]
        }
    }
}

extension View {
    func sidebarWorkspaceFrameAnchor(id: UUID, isEnabled: Bool) -> some View {
        modifier(SidebarWorkspaceFrameAnchorModifier(id: id, isEnabled: isEnabled))
    }
}

struct SidebarWorkspaceRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}
