import AppKit
import CmuxAppKitSupportUI
import CmuxBrowser
import CmuxCommandPalette
import CmuxCommandPaletteUI
import CmuxCore
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
import CmuxPanes
import CmuxSettings
import CmuxWindowing
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
import CmuxSidebarUI
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

var fileDropOverlayKey: UInt8 = 0
let tmuxWorkspacePaneOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.tmuxWorkspacePane.overlay.container")

// CommandPaletteOverlayContainerView, PassthroughWindowOverlayContainerView (now
// the shared CmuxAppKitSupportUI.PassthroughOverlayContainerView), the
// debugCommandPalette* summarizers (now CmuxCommandPaletteUI DEBUG-only
// commandPaletteDebugSummary/commandPaletteDebugPreview extensions on
// NSWindow/NSEvent/NSEvent.ModifierFlags/String/NSResponder),
// WindowCommandPaletteOverlayController, its per-window factory (now
// WindowCommandPaletteOverlayController.installed(in:)), and commandPaletteOwningWebView
// (now NSResponder.commandPaletteOwningWebView) live in CmuxCommandPaletteUI.
//
// The window-level tmux pane overlay controller and its per-window factory now
// live in CmuxWorkspaces (TmuxWorkspacePaneOverlayController +
// TmuxWorkspacePaneOverlayRegistry), driven by the AppTmuxWorkspacePaneOverlayTarget
// seam. ContentView holds one TmuxWorkspacePaneOverlayRegistry property and
// forwards through it. The render-state producer
// tmuxWorkspacePaneWindowOverlayState(for:) stays here: it reads live
// TabManager/Workspace/sidebar god state and is the irreducible seam-bound DTO
// source.

// Lifted to `CmuxFoundation.WorkspaceMountPlan` / `MountedWorkspacePresentation`
// (ContentView decomposition). These typealiases keep call sites short.
typealias WorkspaceMountPlan = CmuxFoundation.WorkspaceMountPlan
typealias MountedWorkspacePresentation = CmuxFoundation.MountedWorkspacePresentation

/// App-side ``CommandPaletteFocusGuard`` adapter for ``ContentView``.
///
/// ``CommandPaletteFocusRestoreController`` (in `CmuxCommandPalette`) owns the
/// pending-target + bounded-timeout lifecycle, but the live focus reads/writes
/// (key window, `TabManager` routing, focused-`Panel` responder restore) cannot
/// live in the package. This long-lived `@State` adapter holds two closures
/// `ContentView` refreshes each render so the controller can call back into the
/// current view value's live state, mirroring the
/// `SelectedWorkspaceDirectoryReadingAdapter` long-lived-adapter pattern. The
/// associated `Target` is `ContentView`'s own `CommandPaletteRestoreFocusTarget`
/// so no app type crosses the module boundary.
@MainActor
private final class CommandPaletteFocusRestoreHost: CommandPaletteFocusGuard {
    typealias Target = ContentView.CommandPaletteRestoreFocusTarget

    var isPaletteStillPresentedProvider: () -> Bool = { false }
    var attemptHandler: (Target) -> CommandPaletteFocusRestoreOutcome = { _ in .targetUnavailable }

    var isPaletteStillPresented: Bool { isPaletteStillPresentedProvider() }

    func attemptRestore(to target: Target) -> CommandPaletteFocusRestoreOutcome {
        attemptHandler(target)
    }
}

struct ContentView: View, CommandPaletteWorkspaceSnapshotProviding, CommandPaletteForkableAgentProbeHost {
    var updateViewModel: UpdateStateModel
    let windowId: UUID
    @Environment(TabManager.self) var tabManager
    // ContentView observes the coalesced unread projection, NOT the notification
    // store. Reading `notificationStore` directly here would re-render the entire
    // content view + sidebar on every notification publish (terminal/agent
    // activity), which reconstructs every workspace row and starves the main
    // thread (issue #2586 class; surfaced as scroll lag). `notificationStore`
    // stays available as an unobserved singleton for actions and pass-down.
    @EnvironmentObject var sidebarUnread: SidebarUnreadModel
    var notificationStore: TerminalNotificationStore { .shared }
    @Environment(SidebarState.self) var sidebarState
    @Environment(SidebarSelectionState.self) var sidebarSelectionState
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore
    @EnvironmentObject var fileExplorerState: FileExplorerState
    @Environment(\.colorScheme) private var colorScheme
    /// Process-wide cross-window sidebar drag registry injected from the app
    /// composition root (`AppDelegate`). Threaded into `VerticalTabsSidebar` so
    /// its `SidebarDragState` is wired to the shared registry without reaching
    /// the `AppDelegate.shared` singleton.
    @Environment(\.sidebarWorkspaceDragRegistry) private var sidebarWorkspaceDragRegistry
    /// Process-lifetime services injected from the app composition root
    /// (`AppDelegate.environment`); `nil` when no environment was injected,
    /// matching the legacy `AppDelegate.shared?` optionality. Internal (not
    /// `private`) so `ContentView` extensions in sibling files can read it.
    @Environment(\.appEnvironment) var appEnvironment
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyleRawValue = TitlebarControlsStyle.classic.rawValue
    @AppStorage(RightSidebarWidthSettings.maxWidthKey) private var rightSidebarMaxWidthSetting = RightSidebarWidthSettings.noOverrideValue
    @AppStorage(SessionPersistencePolicy.sidebarMinimumWidthKey) private var sidebarMinimumWidthSetting = SessionPersistencePolicy.defaultMinimumSidebarWidth
    @AppStorage(MinimalModeTitlebarDebugSnapshot.leftControlsLeadingInsetKey) private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSnapshot.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSnapshot.leftControlsTopInsetKey) private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSnapshot.defaultLeftControlsTopInset
    @AppStorage(MinimalModeTitlebarDebugSnapshot.trafficLightTabBarInsetKey) private var titlebarTrafficLightTabBarInset = MinimalModeTitlebarDebugSnapshot.defaultTrafficLightTabBarInset
    @AppStorage(MinimalModeTitlebarDebugSnapshot.trafficLightTitlebarLeadingInsetKey) private var titlebarTrafficLightTitlebarLeadingInset = MinimalModeTitlebarDebugSnapshot.defaultTrafficLightTitlebarLeadingInset
    @AppStorage(PaneChromeSettings.activePaneBorderColorKey) private var activePaneBorderColorHex = PaneChromeSettings.defaultColorHex
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @State private var sidebarWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
    @State private var selectedTabIds: Set<UUID> = []
    @State private var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var isFullScreen: Bool = false
    @State private var observedWindow: NSWindow?
    @State private var sidebarRenderWorkerClient: RenderWorkerClient?
    @State private var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @StateObject private var fileExplorerStore = FileExplorerStore()
    @State private var sessionIndexStore = SessionIndexStore()
    @State private var selectedWorkspaceDirectoryModel = SelectedWorkspaceDirectoryModel()
    @State private var selectedWorkspaceDirectoryReading = SelectedWorkspaceDirectoryReadingAdapter()
    @State private var tmuxWorkspacePaneOverlayRegistry = TmuxWorkspacePaneOverlayRegistry(
        target: AppTmuxWorkspacePaneOverlayTarget()
    )
    @State private var commandPaletteCoordinator = CommandPaletteCoordinator()
    @State private var backgroundWorkspacePrimeCoordinator = BackgroundWorkspacePrimeCoordinator()
    @State private var fileExplorerWidth: CGFloat = 220
    // Owns the per-window mounted-workspace set + the workspace-handoff state
    // machine (legacy mountedWorkspaceIds / retiringWorkspaceId /
    // previousSelectedWorkspaceId / workspaceHandoffGeneration /
    // workspaceHandoffFallbackTask plus reconcileMountedWorkspaceIds and the
    // startWorkspaceHandoffIfNeeded/complete* methods). Wired to TabManager via
    // WorkspaceHandoffHosting in `.onAppear`; the view observes its
    // mountedWorkspaceIds/retiringWorkspaceId through Observation.
    @State private var workspaceHandoffCoordinator = WorkspaceHandoffCoordinator()
    @State private var didApplyUITestSidebarSelection = false
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State private var sidebarDraggedTabId: UUID?
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    /// Owns the transient cursor / hit-band / pointer-monitor / drag-active state
    /// for the two sidebar resizer dividers. The width math and overlay views stay
    /// here (they write SwiftUI `@State` widths directly); this controller keeps the
    /// resize cursor pinned and is driven by `updateSidebarResizerBandState` and the
    /// overlay gesture/hover handlers.
    @State private var sidebarResizerController = SidebarResizerController(
        bandPolicy: ContentView.bandPolicy,
        fixedSidebarResizeCursor: ContentView.fixedSidebarResizeCursor
    )
    @State private var isCommandPalettePresented = false
    /// Transient editor/query/scroll/draft + usage-history state for this window's
    /// command palette. Owns query, mode, rename/description drafts, selection
    /// index/anchor, scroll target, queued activation/text-selection behavior, the
    /// results revision, and persisted usage history (one writer each). Visibility,
    /// escape suppression, and per-window selection stay on the window store.
    @State private var commandPalettePresentation = CommandPalettePresentationModel(
        defaultWorkspaceDescriptionHeight: CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
    )
    @State private var commandPaletteRestoreFocusTarget: CommandPaletteRestoreFocusTarget?
    // commandPaletteSearchCorpus / commandPaletteSearchCorpusByID /
    // commandPaletteSearchCommandsByID / commandPaletteNucleoSearchIndex and the
    // index-build task/generation now live on `commandPaletteCoordinator`
    // (single-writer @Observable corpus pipeline). See `CommandPaletteCoordinator+SearchCorpus`.
    // The imperative search-results pipeline state (cachedResults, visibleResults
    // [+version/scope/fingerprint], the in-flight search task, the request-id and
    // resolved-search trackers, and the search-pending flag) now lives on
    // `commandPaletteCoordinator` as its single writer. ContentView reads/writes
    // them through the coordinator. cachedCorpusScope / cachedCorpusFingerprint
    // (formerly cachedCommandPaletteScope / cachedCommandPaletteFingerprint) also
    // live there.
    @State private var cachedDefaultTerminalIsDefault = AppDelegate.defaultTerminalRegistrationStatus().isDefault
    // Post-dismiss focus-restore lifecycle (pending dismiss target + bounded
    // timeout) now lives on `commandPaletteFocusRestoreController`, replacing the
    // former `DispatchWorkItem`+`asyncAfter` deadline with an injected-Clock Task.
    @State private var commandPaletteFocusRestoreHost = CommandPaletteFocusRestoreHost()
    @State private var commandPaletteFocusRestoreController =
        CommandPaletteFocusRestoreController<CommandPaletteFocusRestoreHost>()
    @State private var sidebarInlineRenameWorkspaceId: UUID?
    @State private var sidebarInlineRenameRequestToken = 0
    // `commandPaletteTerminalOpenTargetAvailability` stays here: its element type
    // `TerminalDirectoryOpenTarget` is an app-target type, so this set cannot move
    // into the package without a DAG violation.
    @State private var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> = []
    /// Owns the command palette's forkable-agent availability cache and the
    /// per-panel capability probe. The cache dictionaries, generation-based
    /// probe cancellation, and the probe lifecycle live in the coordinator; the
    /// snapshot-type-aware reads stay here behind
    /// ``CommandPaletteForkableAgentProbeHost`` conformance.
    @State var commandPaletteForkableAgentProbeCoordinator = CommandPaletteForkableAgentProbeCoordinator<ContentView>()
    /// Owns the command palette's rename and workspace-description flow logic.
    /// The seed, validate, and apply transitions live in the coordinator; every
    /// app-target read or write (workspace lookup, title mutation, focus reset,
    /// present, dismiss, beep, DEBUG log) stays here behind
    /// ``CommandPaletteEditFlowHost`` conformance.
    private let commandPaletteEditFlowCoordinator = CommandPaletteEditFlowCoordinator()
    @State private var feedbackComposerCoordinator = FeedbackComposerCoordinator()
    @AppStorage(AppCatalogSection().renameSelectsExistingName.userDefaultsKey)
    private var commandPaletteRenameSelectAllOnFocus = AppCatalogSection().renameSelectsExistingName.defaultValue
    @AppStorage(AppCatalogSection().commandPaletteSearchesAllSurfaces.userDefaultsKey)
    private var commandPaletteSearchAllSurfaces = AppCatalogSection().commandPaletteSearchesAllSurfaces.defaultValue
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @State private var commandPaletteShouldFocusWorkspaceDescriptionEditor = false
    @FocusState private var isCommandPaletteSearchFocused: Bool
    @FocusState private var isCommandPaletteRenameFocused: Bool
    private let windowChrome = AppWindowChromeComposition()

    struct CommandPaletteRestoreFocusTarget {
        let workspaceId: UUID
        let panelId: UUID
        let intent: PanelFocusIntent
    }

    static func tmuxWorkspacePaneExactRect(
        for panel: Panel,
        in contentView: NSView
    ) -> CGRect? {
        let targetView: NSView?
        switch panel {
        case let terminal as TerminalPanel:
            targetView = terminal.hostedView
        case let browser as BrowserPanel:
            targetView = browser.webView
        default:
            targetView = nil
        }
        guard let targetView else { return nil }
        return TmuxPaneOverlayGeometry.exactRect(for: targetView, in: contentView)
    }

    private func tmuxWorkspacePaneWindowOverlayState(for window: NSWindow) -> TmuxWorkspacePaneOverlayRenderState? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let usesWorkspacePaneOverlay = TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay
        let resolvedActivePaneBorderColorHex = WorkspaceTabColorSettings().normalizedHex(activePaneBorderColorHex)
        let shouldShowActivePaneBorder = shouldShowActivePaneBorder(for: workspace, colorHex: resolvedActivePaneBorderColorHex)
        guard usesWorkspacePaneOverlay || shouldShowActivePaneBorder else { return nil }

        let overlayResolver = WorkspacePaneOverlayRectResolver()
        let layoutSnapshot = overlayResolver.effectiveLayoutSnapshot(
            cachedSnapshot: workspace.tmuxLayoutSnapshot,
            liveSnapshot: workspace.bonsplitController.layoutSnapshot()
        )
        let contentView = window.contentView

        let unreadRects: [CGRect]
        if usesWorkspacePaneOverlay {
            let isWorkspaceManuallyUnread = sidebarUnread.hasManualUnread(forWorkspaceId: workspace.id)
            let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()
            if let layoutSnapshot, let contentView {
                unreadRects = layoutSnapshot.panes.compactMap { pane in
                    guard let selectedTabId = pane.selectedTabId,
                          let tabUUID = UUID(uuidString: selectedTabId),
                          let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)),
                          let panel = workspace.panels[panelId] else {
                        return nil
                    }

                    let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                        hasUnreadNotification: sidebarUnread.hasVisibleNotificationIndicator(
                            forWorkspaceId: workspace.id,
                            surfaceId: panelId
                        ),
                        hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panelId) ||
                            workspace.restoredUnreadPanelIds.contains(panelId),
                        isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                        isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panelId
                    )
                    guard shouldShowUnread else { return nil }

                    let paneRect = overlayResolver.paneWindowOverlayRect(
                        layoutSnapshot: layoutSnapshot,
                        paneId: workspace.paneId(forPanelId: panelId)
                    )
                    let exactRect = Self.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
                    return TmuxPaneOverlayGeometry.preferredWindowOverlayRect(
                        exactRect: exactRect,
                        paneRect: paneRect
                    )
                }
            } else {
                unreadRects = overlayResolver.paneWindowUnreadRects(
                    workspace: workspace,
                    notificationStore: notificationStore,
                    layoutSnapshot: layoutSnapshot
                )
            }
        } else {
            unreadRects = []
        }

        let flashRect: CGRect?
        if usesWorkspacePaneOverlay {
            if let panelId = workspace.tmuxWorkspaceFlashPanelId,
               let panel = workspace.panels[panelId],
               let contentView {
                let paneRect = overlayResolver.paneWindowOverlayRect(
                    layoutSnapshot: layoutSnapshot,
                    paneId: workspace.paneId(forPanelId: panelId)
                )
                let exactRect = Self.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
                flashRect = TmuxPaneOverlayGeometry.preferredWindowOverlayRect(
                    exactRect: exactRect,
                    paneRect: paneRect
                )
            } else {
                flashRect = overlayResolver.paneWindowOverlayRect(
                    layoutSnapshot: layoutSnapshot,
                    paneId: workspace.tmuxWorkspaceFlashPanelId.flatMap { workspace.paneId(forPanelId: $0) }
                )
            }
        } else {
            flashRect = nil
        }

        let activePaneBorderRect: CGRect?
        if shouldShowActivePaneBorder,
           let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId] {
            let paneRect = overlayResolver.paneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.paneId(forPanelId: panelId)
            )
            let exactRect = contentView.flatMap { Self.tmuxWorkspacePaneExactRect(for: panel, in: $0) }
            activePaneBorderRect = TmuxPaneOverlayGeometry.preferredWindowOverlayRect(
                exactRect: exactRect,
                paneRect: paneRect
            )
        } else {
            activePaneBorderRect = nil
        }

        if unreadRects.isEmpty, flashRect == nil, activePaneBorderRect == nil {
            guard usesWorkspacePaneOverlay else { return nil }
            return TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspace.id,
                unreadRects: [],
                flashRect: nil,
                activePaneBorderRect: nil,
                activePaneBorderColorHex: nil,
                flashToken: workspace.tmuxWorkspaceFlashToken,
                flashReason: workspace.tmuxWorkspaceFlashReason
            )
        }

        return TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspace.id,
            unreadRects: unreadRects,
            flashRect: flashRect,
            activePaneBorderRect: activePaneBorderRect,
            activePaneBorderColorHex: activePaneBorderRect == nil ? nil : resolvedActivePaneBorderColorHex,
            flashToken: workspace.tmuxWorkspaceFlashToken,
            flashReason: workspace.tmuxWorkspaceFlashReason
        )
    }

    private func refreshTmuxWorkspacePaneWindowOverlay(in window: NSWindow?) {
        guard let window else { return }
        let tmuxOverlayState = tmuxWorkspacePaneWindowOverlayState(for: window)
        WindowTmuxWorkspacePaneOverlayController.controller(
            for: window,
            createIfNeeded: tmuxOverlayState != nil
        )?.update(state: tmuxOverlayState)
    }

    private func shouldShowActivePaneBorder(for workspace: Workspace, colorHex: String?) -> Bool {
        colorHex != nil && workspace.layoutMode != .canvas && !fileExplorerState.rightSidebarOwnsInputFocus && workspace.bonsplitController.allPaneIds.count > 1
    }

    private func shouldScheduleTmuxWorkspacePaneWindowOverlayGeometryRefresh(in window: NSWindow) -> Bool {
        if TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay { return true }
        if WindowTmuxWorkspacePaneOverlayController.controller(for: window, createIfNeeded: false)?.hasRenderedState == true { return true }
        guard let workspace = tabManager.selectedWorkspace else { return false }
        return shouldShowActivePaneBorder(for: workspace, colorHex: WorkspaceTabColorSettings().normalizedHex(activePaneBorderColorHex))
    }

    private func scheduleTmuxWorkspacePaneWindowOverlayGeometryRefresh(in window: NSWindow?) {
        guard let window,
              shouldScheduleTmuxWorkspacePaneWindowOverlayGeometryRefresh(in: window),
              let controller = WindowTmuxWorkspacePaneOverlayController.controller(for: window, createIfNeeded: true) else { return }
        controller.scheduleGeometryRefresh { [weak window] in
            guard let window else { return nil }
            return tmuxWorkspacePaneWindowOverlayState(for: window)
        }
    }

    private struct CommandPaletteSwitcherWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let selectedWorkspaceId: UUID?
        let windowLabel: String?
    }

    private static let fixedSidebarResizeCursor = NSCursor(
        image: NSCursor.resizeLeftRight.image,
        hotSpot: NSCursor.resizeLeftRight.hotSpot
    )
    nonisolated private static let commandPaletteQueryScopePolicy = CommandPaletteQueryScopePolicy()
    private static let minimumRightSidebarWidth: CGFloat = CGFloat(RightSidebarWidthSettings.minimumWidth)
    private static let maximumRightSidebarWidth: CGFloat = CGFloat(RightSidebarWidthSettings.builtInMaximumWidth)
    private static let minimumTerminalWidthWithRightSidebar: CGFloat = 360

    private var minimumSidebarWidth: CGFloat {
        Self.resizerGeometryPolicy.minimumSidebarWidth(setting: CGFloat(sidebarMinimumWidthSetting))
    }

    /// Returns the current drag width, start width capture, width update, and drag end cleanup for a resizer handle.
    private func resizerConfig(for handle: SidebarResizerHandle, availableWidth: CGFloat) -> (
        currentWidth: CGFloat,
        captureStart: () -> Void,
        updateWidth: (CGFloat) -> Void,
        finishDrag: () -> Void
    ) {
        switch handle {
        case .divider:
            return (
                currentWidth: sidebarWidth,
                captureStart: { sidebarResizerController.sidebarDragStartWidth = sidebarWidth },
                updateWidth: { translation in
                    let startWidth = sidebarResizerController.sidebarDragStartWidth ?? sidebarWidth
                    let nextWidth = Self.resizerGeometryPolicy.normalizedSidebarWidth(
                        startWidth + translation,
                        maximumWidth: maxSidebarWidth(availableWidth: availableWidth),
                        minimumWidth: minimumSidebarWidth
                    )
                    withTransaction(Transaction(animation: nil)) {
                        sidebarWidth = nextWidth
                    }
                },
                finishDrag: { sidebarResizerController.sidebarDragStartWidth = nil }
            )
        case .explorerDivider:
            return (
                currentWidth: fileExplorerWidth,
                captureStart: { sidebarResizerController.fileExplorerDragStartWidth = fileExplorerWidth },
                updateWidth: { translation in
                    let startWidth = sidebarResizerController.fileExplorerDragStartWidth ?? fileExplorerWidth
                    let nextWidth = Self.resizerGeometryPolicy.normalizedRightSidebarWidth(
                        startWidth - translation,
                        availableWidth: availableWidth,
                        configuredMaximumWidth: rightSidebarConfiguredMaximumWidth
                    )
                    withTransaction(Transaction(animation: nil)) {
                        fileExplorerWidth = nextWidth
                    }
                },
                finishDrag: {
                    sidebarResizerController.fileExplorerDragStartWidth = nil
                    fileExplorerState.width = fileExplorerWidth
                }
            )
        }
    }

    private func maxSidebarWidth(availableWidth: CGFloat? = nil) -> CGFloat {
        let resolvedAvailableWidth = availableWidth
            ?? observedWindow?.contentView?.bounds.width
            ?? observedWindow?.contentLayoutRect.width
            ?? NSApp.keyWindow?.contentView?.bounds.width
            ?? NSApp.keyWindow?.contentLayoutRect.width
        if let resolvedAvailableWidth, resolvedAvailableWidth > 0 {
            return Self.resizerGeometryPolicy.maxSidebarWidth(
                resolvedAvailableWidth: resolvedAvailableWidth,
                fallbackScreenWidth: nil,
                minimumWidth: minimumSidebarWidth
            )
        }

        let fallbackScreenWidth = NSApp.keyWindow?.screen?.frame.width
            ?? NSScreen.main?.frame.width
        return Self.resizerGeometryPolicy.maxSidebarWidth(
            resolvedAvailableWidth: nil,
            fallbackScreenWidth: fallbackScreenWidth,
            minimumWidth: minimumSidebarWidth
        )
    }

    /// The pure width-clamp policy for both sidebar dividers, configured with the
    /// app's fixed sidebar layout constants. The math lives in `CmuxSidebar`; this
    /// is the production composition of its bounds.
    static let widthPolicy = SidebarWidthPolicy(
        defaultSidebarWidth: CGFloat(SessionPersistencePolicy.defaultSidebarWidth),
        minimumRightSidebarWidth: Self.minimumRightSidebarWidth,
        maximumRightSidebarWidth: Self.maximumRightSidebarWidth,
        minimumTerminalWidthWithRightSidebar: Self.minimumTerminalWidthWithRightSidebar
    )

    /// The pure resizer hit-band geometry for both dividers. The math lives in
    /// `CmuxSidebar`; `SidebarResizeInteraction.bandPolicy` is the single
    /// composition of its bounds from the app's hit-width constants, shared with
    /// the portal hit-test paths so the geometry lives in exactly one place.
    static let bandPolicy = SidebarResizeInteraction.bandPolicy

    /// The pure resizer geometry policy for both sidebar dividers, composed from
    /// the app's fixed layout constants. The math lives in `CmuxSidebar`; this is
    /// the production composition of its bounds. The view resolves live window /
    /// screen widths and persisted settings and forwards them into this policy.
    static let resizerGeometryPolicy = SidebarResizerGeometryPolicy(
        widthPolicy: Self.widthPolicy,
        defaultMinimumSidebarWidth: CGFloat(SessionPersistencePolicy.defaultMinimumSidebarWidth),
        minimumSidebarWidthRange: CGFloat(SessionPersistencePolicy.sidebarMinimumWidthRange.lowerBound)
            ... CGFloat(SessionPersistencePolicy.sidebarMinimumWidthRange.upperBound)
    )

    private func clampSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = Self.resizerGeometryPolicy.normalizedSidebarWidth(
            sidebarWidth,
            maximumWidth: maxSidebarWidth(availableWidth: availableWidth),
            minimumWidth: minimumSidebarWidth
        )
        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            sidebarWidth = nextWidth
        }
    }

    private func normalizedSidebarWidth(_ candidate: CGFloat) -> CGFloat {
        Self.resizerGeometryPolicy.normalizedSidebarWidth(
            candidate,
            maximumWidth: maxSidebarWidth(),
            minimumWidth: minimumSidebarWidth
        )
    }

    private func resolvedRightSidebarAvailableWidth(_ availableWidth: CGFloat? = nil) -> CGFloat {
        Self.resizerGeometryPolicy.resolvedRightSidebarAvailableWidth(
            resolvedWidths: [
                availableWidth,
                observedWindow?.contentView?.bounds.width,
                observedWindow?.contentLayoutRect.width,
                NSApp.keyWindow?.contentView?.bounds.width,
                NSApp.keyWindow?.contentLayoutRect.width,
                NSApp.keyWindow?.screen?.frame.width,
                NSScreen.main?.frame.width,
            ]
        )
    }

    private var rightSidebarConfiguredMaximumWidth: CGFloat? {
        Self.resizerGeometryPolicy.rightSidebarConfiguredMaximumWidth(setting: rightSidebarMaxWidthSetting)
    }

    private func normalizedRightSidebarWidth(_ candidate: CGFloat, availableWidth: CGFloat? = nil) -> CGFloat {
        Self.resizerGeometryPolicy.normalizedRightSidebarWidth(
            candidate,
            availableWidth: resolvedRightSidebarAvailableWidth(availableWidth),
            configuredMaximumWidth: rightSidebarConfiguredMaximumWidth
        )
    }

    private func clampRightSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = normalizedRightSidebarWidth(fileExplorerWidth, availableWidth: availableWidth)
        guard abs(nextWidth - fileExplorerWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            fileExplorerWidth = nextWidth
        }
        fileExplorerState.width = nextWidth
    }

    /// Builds the live divider-geometry snapshot the resizer controller needs.
    /// The leading divider is the absolute `sidebarWidth`; the trailing divider is
    /// the right-explorer width inset from the content's right edge.
    private func sidebarResizerBandInputs() -> SidebarResizerBandInputs {
        SidebarResizerBandInputs(
            window: observedWindow,
            leftDividerVisible: sidebarState.isVisible,
            leftDividerX: sidebarWidth,
            rightDividerVisible: rightSidebarVisible,
            rightSidebarWidth: rightSidebarWidth
        )
    }

    private func updateSidebarResizerBandState() {
        sidebarResizerController.updateBandState(inputs: sidebarResizerBandInputs())
    }

    private func installSidebarResizerPointerMonitorIfNeeded() {
        sidebarResizerController.attach(bandInputsProvider: sidebarResizerBandInputs)
        sidebarResizerController.installSidebarResizerPointerMonitorIfNeeded(window: observedWindow)
    }

    private func removeSidebarResizerPointerMonitor() {
        sidebarResizerController.removeSidebarResizerPointerMonitor()
    }

    private func sidebarResizerHandleOverlay(
        _ handle: SidebarResizerHandle,
        width: CGFloat,
        availableWidth: CGFloat,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    sidebarResizerController.handleHoverBegan(handle)
                } else {
                    sidebarResizerController.handleHoverEnded(handle)
                }
                updateSidebarResizerBandState()
            }
            .onDisappear {
                if sidebarResizerController.isResizerDragging {
                    TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                    sidebarResizerController.endDrag()
                }
                sidebarResizerController.sidebarDragStartWidth = nil
                sidebarResizerController.handleDidDisappear(handle)
                sidebarResizerController.scheduleSidebarResizerCursorRelease(force: true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let config = resizerConfig(for: handle, availableWidth: availableWidth)
                        if !sidebarResizerController.isResizerDragging {
                            TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
                            sidebarResizerController.beginDrag()
                            config.captureStart()
                        }
                        sidebarResizerController.activateSidebarResizerCursor()
                        config.updateWidth(value.translation.width)
                    }
                    .onEnded { _ in
                        if sidebarResizerController.isResizerDragging {
                            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                            sidebarResizerController.endDrag()
                            let config = resizerConfig(for: handle, availableWidth: availableWidth)
                            config.finishDrag()
                        }
                        sidebarResizerController.activateSidebarResizerCursor()
                        sidebarResizerController.scheduleSidebarResizerCursorRelease()
                    }
            )
            .modifier(SidebarResizerAccessibilityModifier(accessibilityIdentifier: accessibilityIdentifier))
    }

    private func placedSidebarResizerOverlay(
        handle: SidebarResizerHandle,
        edge: SidebarResizeInteraction.Edge,
        accessibilityIdentifier: String,
        dividerX: @escaping (CGFloat) -> CGFloat
    ) -> some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width)
            let resolvedDividerX = min(max(dividerX(totalWidth), 0), totalWidth)
            let leadingWidth = max(0, edge.handleX(dividerX: resolvedDividerX))

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingWidth)
                    .allowsHitTesting(false)

                sidebarResizerHandleOverlay(
                    handle,
                    width: SidebarResizeInteraction.totalHitWidth,
                    availableWidth: totalWidth,
                    accessibilityIdentifier: accessibilityIdentifier
                )

                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
        }
    }

    private var sidebarResizerOverlay: some View {
        placedSidebarResizerOverlay(
            handle: .divider,
            edge: .leading,
            accessibilityIdentifier: "SidebarResizer",
            dividerX: { totalWidth in min(max(sidebarWidth, 0), totalWidth) }
        )
    }

    private var rightSidebarResizerOverlay: some View {
        placedSidebarResizerOverlay(
            handle: .explorerDivider,
            edge: .trailing,
            accessibilityIdentifier: "RightSidebarResizer",
            dividerX: { totalWidth in totalWidth - rightSidebarWidth }
        )
    }

    private var sidebarView: some View {
        @Bindable var sidebarSelectionState = sidebarSelectionState
        return VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            fileExplorerState: fileExplorerState,
            windowId: windowId,
            onSendFeedback: feedbackComposerCoordinator.present,
            onToggleSidebar: { sidebarState.toggle() },
            onNewTab: {
                appEnvironment?.mainWindowRouter.performNewWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "titlebar.hiddenNewWorkspace"
                )
            },
            observedWindow: observedWindow,
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds, lastSidebarSelectionIndex: $lastSidebarSelectionIndex, sidebarRenderWorkerClient: $sidebarRenderWorkerClient,
            inlineRenameWorkspaceId: $sidebarInlineRenameWorkspaceId,
            inlineRenameRequestToken: $sidebarInlineRenameRequestToken,
            workspaceDragRegistry: sidebarWorkspaceDragRegistry ?? SidebarWorkspaceDragRegistry()
        )
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// Native titlebar inset reported by AppKit. Standard mode follows cmux's visual chrome;
    /// minimal WindowGroup hosts can still need the reported safe area cancelled.
    @State private var titlebarPadding: CGFloat = WindowChromeMetrics.defaultTitlebarHeight
    /// SwiftUI WindowGroup windows can still report a titlebar safe area; manually created
    /// main windows use MainWindowHostingView and report zero.
    @State private var hostingSafeAreaTop: CGFloat = 0
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var effectiveTitlebarPadding: CGFloat {
        Self.effectiveTitlebarPadding(
            isMinimalMode: isMinimalMode,
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        )
    }

    static func effectiveTitlebarPadding(
        isMinimalMode: Bool,
        isFullScreen: Bool,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat
    ) -> CGFloat {
        WindowTitlebarLayout().effectiveTitlebarPadding(
            isMinimalMode: isMinimalMode,
            isFullScreen: isFullScreen,
            appTitlebarHeight: WindowChromeMetrics.appTitlebarHeight,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        )
    }

    nonisolated static func customTitlebarLeadingPadding(
        isFullScreen: Bool,
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        titlebarLeadingInset: CGFloat
    ) -> CGFloat {
        WindowTitlebarLayout().customTitlebarLeadingPadding(
            isFullScreen: isFullScreen,
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth,
            titlebarLeadingInset: titlebarLeadingInset
        )
    }

    /// Where the always-visible fullscreen titlebar controls (sidebar toggle,
    /// history, new tab, notifications) are anchored inside the titlebar band.
    typealias FullscreenControlsPlacement = CmuxAppKitSupportUI.FullscreenControlsPlacement

    /// Resolves the placement for the fullscreen titlebar controls, or `nil` when
    /// they should not be shown. The controls are mounted in a single overlay
    /// anchor driven by this function so their on-screen position never depends on
    /// sidebar visibility; toggling the sidebar must not shift the accessory bar.
    nonisolated static func fullscreenControlsPlacement(
        isFullScreen: Bool,
        isSidebarVisible: Bool
    ) -> FullscreenControlsPlacement? {
        WindowTitlebarLayout().fullscreenControlsPlacement(
            isFullScreen: isFullScreen,
            isSidebarVisible: isSidebarVisible
        )
    }

    private func terminalContent(appearance: WindowAppearanceSnapshot) -> some View {
        @Bindable var sidebarSelectionState = sidebarSelectionState
        let mountedWorkspaceIdSet = Set(workspaceHandoffCoordinator.mountedWorkspaceIds)
        let mountedWorkspaces = tabManager.tabs.filter { mountedWorkspaceIdSet.contains($0.id) }
        let selectedWorkspaceId = tabManager.selectedTabId
        let retiringWorkspaceId = workspaceHandoffCoordinator.retiringWorkspaceId

        return ZStack {
            ZStack {
                ForEach(mountedWorkspaces) { tab in
                    let isSelectedWorkspace = selectedWorkspaceId == tab.id
                    let isRetiringWorkspace = retiringWorkspaceId == tab.id
                    let presentation = MountedWorkspacePresentation.resolve(
                        isSelectedWorkspace: isSelectedWorkspace,
                        isRetiringWorkspace: isRetiringWorkspace
                    )
                    // Keep the retiring workspace visible during handoff, but never input-active.
                    // Allowing both selected+retiring workspaces to be input-active lets the
                    // old workspace steal first responder (notably with WKWebView), which can
                    // delay handoff completion and make browser returns feel laggy.
                    let isInputActive = isSelectedWorkspace
                    let portalPriority = isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0)
                    WorkspaceContentView(
                        workspace: tab,
                        isWorkspaceVisible: presentation.isPanelVisible,
                        isWorkspaceInputActive: isInputActive,
                        isFullScreen: isFullScreen,
                        workspacePortalPriority: portalPriority,
                        windowAppearance: appearance,
                        onThemeRefreshRequest: { reason, eventId, source, payloadHex in
                            scheduleTitlebarThemeRefreshFromWorkspace(
                                workspaceId: tab.id,
                                reason: reason,
                                backgroundEventId: eventId,
                                backgroundSource: source,
                                notificationPayloadHex: payloadHex
                            )
                        }
                    )
                    .opacity(presentation.renderOpacity)
                    .allowsHitTesting(isSelectedWorkspace)
                    .accessibilityHidden(!presentation.isRenderedVisible)
                    .zIndex(isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0))
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)
            .accessibilityHidden(sidebarSelectionState.selection != .tabs)

            NotificationsPage(selection: $sidebarSelectionState.selection)
                .opacity(sidebarSelectionState.selection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelectionState.selection == .notifications)
                .accessibilityHidden(sidebarSelectionState.selection != .notifications)
        }
        .padding(.top, effectiveTitlebarPadding)
        .overlay(alignment: .top) {
            if let guardrail = appEnvironment?.paneMemoryGuardrail {
                PaneMemoryGuardrailBanner(guardrail: guardrail, tabManager: tabManager)
            }
        }
    }

    private func terminalContentWithSidebarDropOverlay(appearance: WindowAppearanceSnapshot) -> some View {
        terminalContent(appearance: appearance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .overlay {
                SidebarExternalDropOverlay(draggedTabId: sidebarDraggedTabId)
            }
    }

    private func terminalContentWithRightSidebarPanel(appearance: WindowAppearanceSnapshot) -> some View {
        // The right-sidebar shell remains in the view tree so its frame can
        // animate without SwiftUI insertion/removal. Cold hidden launches defer
        // heavy mode content until the sidebar has been shown at least once.
        return HStack(spacing: 0) {
            terminalContentWithSidebarDropOverlay(appearance: appearance)
            rightSidebarPanelWithBackdrop(appearance: appearance)
        }
    }

    private var rightSidebarVisible: Bool {
        fileExplorerState.isVisible
    }

    private var rightSidebarWidth: CGFloat {
        rightSidebarVisible ? fileExplorerWidth : 0
    }

    private func sidebarBackdropLayer(
        width: CGFloat,
        role: WindowBackdropRole,
        appearance: WindowAppearanceSnapshot
    ) -> some View {
        WindowBackdropLayer(role: role, snapshot: appearance)
            .ignoresSafeArea()
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: appearance.sidebarSettings.materialPolicy.cornerRadius, style: .continuous))
            .clipped()
            .allowsHitTesting(false)
    }

    private func sidebarPanelContainer<Content: View>(
        width: CGFloat,
        alignment: Alignment,
        role: WindowBackdropRole,
        appearance: WindowAppearanceSnapshot,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            sidebarBackdropLayer(width: width, role: role, appearance: appearance)
            content()
                .environment(\.colorScheme, appearance.sidebarContentColorScheme)
        }
        .frame(width: width)
    }

    private func sidebarPanelWithBackdrop(appearance: WindowAppearanceSnapshot) -> some View {
        sidebarPanelContainer(width: sidebarWidth, alignment: .leading, role: .leftSidebar, appearance: appearance) {
            sidebarView
        }
    }

    private func rightSidebarPanelWithBackdrop(appearance: WindowAppearanceSnapshot) -> some View {
        let panel = sidebarPanelContainer(width: rightSidebarWidth, alignment: .trailing, role: .rightSidebar, appearance: appearance) {
            rightSidebarPanel
        }
        .overlay(alignment: .leading) {
            if rightSidebarVisible {
                WindowChromeBorder(
                    orientation: .vertical,
                    refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
                    backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
                )
            }
        }

        return panel
    }

    private var rightSidebarPanel: some View {
        return RightSidebarPanelView(
            tabManager: tabManager,
            fileExplorerStore: fileExplorerStore,
            fileExplorerState: fileExplorerState,
            sessionIndexStore: sessionIndexStore,
            titlebarHeight: RightSidebarChromeMetrics.titlebarHeight,
            workspaceId: tabManager.selectedTabId,
            onResumeSession: { entry in
                resumeSession(entry: entry)
            },
            onOpenFilePreview: { filePath in
                openFilePreviewFromSidebar(filePath: filePath)
            },
            onOpenAsPane: { mode in
                openRightSidebarToolPane(mode)
            },
            onClose: {
                #if DEBUG
                cmuxDebugLog("rightSidebar.closeButton")
                #endif
                _ = appEnvironment?.mainWindowRouter.closeRightSidebarInActiveWindow(preferredWindow: observedWindow)
            }
        )
        .frame(width: rightSidebarWidth)
        .clipped()
        .allowsHitTesting(rightSidebarVisible)
        .accessibilityHidden(!rightSidebarVisible)
        .transaction { $0.animation = nil }
        .onAppear {
            let sanitized = normalizedRightSidebarWidth(fileExplorerState.width)
            fileExplorerWidth = sanitized
            if abs(fileExplorerState.width - sanitized) > 0.5 {
                DispatchQueue.main.async {
                    fileExplorerState.width = sanitized
                }
            }
        }
        .onChange(of: fileExplorerState.width) { newValue in
            if sidebarResizerController.fileExplorerDragStartWidth == nil {
                let sanitized = normalizedRightSidebarWidth(newValue)
                if abs(newValue - sanitized) > 0.5 {
                    DispatchQueue.main.async {
                        fileExplorerState.width = sanitized
                    }
                    return
                }
                fileExplorerWidth = sanitized
            }
        }
    }

    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarMatchTerminalBackground") private var sidebarMatchTerminalBackground = false
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults().opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults().hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarState") private var sidebarStateSetting = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0

    // Background glass settings
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false
    @State private var titlebarLeadingInset: CGFloat = 12
    private var windowIdentifier: String { "cmux.main.\(windowId.uuidString)" }
    private var windowAppearanceSnapshot: WindowAppearanceSnapshot {
        _ = titlebarThemeGeneration
        return windowChrome.appearanceSnapshot(
            settings: WindowAppearanceUserSettingsSnapshot(
                unifySurfaceBackdrops: sidebarMatchTerminalBackground,
                colorScheme: AppearanceSettings.colorScheme(for: appearanceMode, fallback: colorScheme),
                sidebarMaterial: sidebarMaterial,
                sidebarBlendMode: sidebarBlendMode,
                sidebarState: sidebarStateSetting,
                sidebarTintHex: sidebarTintHex,
                sidebarTintHexLight: sidebarTintHexLight,
                sidebarTintHexDark: sidebarTintHexDark,
                sidebarTintOpacity: sidebarTintOpacity,
                sidebarCornerRadius: sidebarCornerRadius,
                sidebarBlurOpacity: sidebarBlurOpacity,
                bgGlassEnabled: bgGlassEnabled,
                bgGlassTintHex: bgGlassTintHex,
                bgGlassTintOpacity: bgGlassTintOpacity
            )
        )
    }

    private func fakeTitlebarTextColor(appearance: WindowAppearanceSnapshot) -> Color {
        let ghosttyBackground = appearance.terminalBackgroundColor
        return ghosttyBackground.isLightColor
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.82)
    }
    private var fullscreenControls: some View {
        TitlebarControlsView(
            notificationStore: TerminalNotificationStore.shared,
            viewModel: fullscreenControlsViewModel,
            onToggleSidebar: { sidebarState.toggle() },
            onToggleNotifications: { [fullscreenControlsViewModel] in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: fullscreenControlsViewModel.notificationsAnchorView
                )
            },
            onNewTab: {
                appEnvironment?.mainWindowRouter.performNewWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "titlebar.fullscreenNewWorkspace"
                )
            },
            onFocusHistoryBack: {
                if !tabManager.navigateBack() {
                    NSSound.beep()
                }
            },
            onFocusHistoryForward: {
                if !tabManager.navigateForward() {
                    NSSound.beep()
                }
            },
            visibilityMode: .alwaysVisible
        )
        .offset(y: -TitlebarControlsVisualMetrics.standard.verticalLift)
    }

    /// Intrinsic width of ``fullscreenControls`` for the current controls style.
    /// Used to reserve space in the title row so the title flows to the right of
    /// the controls, which are themselves mounted once in the band overlay.
    private var fullscreenControlsWidth: CGFloat {
        let style = TitlebarControlsStyle(rawValue: titlebarControlsStyleRawValue) ?? .classic
        return style.config.contentSize().width
    }

    private var titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSnapshot.clamped(
                titlebarLeftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSnapshot.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSnapshot.clamped(
                titlebarLeftControlsTopInset,
                range: MinimalModeTitlebarDebugSnapshot.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSnapshot.clamped(
                titlebarTrafficLightTabBarInset,
                range: MinimalModeTitlebarDebugSnapshot.horizontalInsetRange
            ),
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSnapshot.clamped(
                titlebarTrafficLightTitlebarLeadingInset,
                range: MinimalModeTitlebarDebugSnapshot.horizontalInsetRange
            )
        )
    }

    private func customTitlebar(appearance: WindowAppearanceSnapshot) -> some View {
        let titlebarContentHeight = max(1, WindowChromeMetrics.appTitlebarHeight - 2)
        let leadingPadding = Self.customTitlebarLeadingPadding(
            isFullScreen: isFullScreen,
            isSidebarVisible: sidebarState.isVisible,
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth,
            titlebarLeadingInset: titlebarLeadingInset
        )
        return ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            TitlebarLeadingInsetReader(
                inset: $titlebarLeadingInset,
                baseLeadingInset: { MinimalModeTitlebarDebugSnapshot.trafficLightTitlebarLeadingInset() }
            )
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                if isFullScreen && !sidebarState.isVisible {
                    // Reserve the controls' width so the title flows to their right.
                    // The visible controls are rendered once in the band overlay (see
                    // `workspaceTitlebarBand`) so their position never depends on
                    // sidebar visibility.
                    Color.clear
                        .frame(width: fullscreenControlsWidth, height: titlebarContentHeight)
                        .allowsHitTesting(false)
                }

                // Draggable folder icon + focused command name
                if let directory = focusedDirectory {
                    DetachedFolderDragIcon(directory: directory)
                        .frame(width: 16, height: 16)
                        .padding(.leading, -6)
                }

                Text(titlebarText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(fakeTitlebarTextColor(appearance: appearance))
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer()

            }
            .frame(height: titlebarContentHeight)
            .padding(.top, 2)
            .padding(.leading, leadingPadding)
            .padding(.trailing, 8)
        }
        .frame(height: WindowChromeMetrics.appTitlebarHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(TitlebarDoubleClickMonitorView())
        .overlay(alignment: .bottom) {
            WindowChromeBorder(
                orientation: .horizontal,
                refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
                backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
            )
                .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
        }
    }

    private func workspaceTitlebarBand(appearance: WindowAppearanceSnapshot) -> some View {
        Color.clear
            .frame(height: WindowChromeMetrics.appTitlebarHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                customTitlebar(appearance: appearance)
                    // The workspace titlebar band spans the full window width and sits at
                    // zIndex(100) over the content/sidebar layout. Its drag/double-click
                    // surface (`WindowDragHandleView` + `.contentShape(Rectangle())`) must
                    // not cover the right sidebar, whose mode bar (Files/Search/Feed/Vault)
                    // lives inside the titlebar-height strip — otherwise the band wins the
                    // hit-test and swallows every click/hover on those buttons (#5099).
                    // Confine the interactive titlebar surface to the area left of the
                    // right sidebar, matching the pre-#5017 "only over terminal content,
                    // not the sidebar" intent. The left sidebar's titlebar controls live in
                    // the AppKit titlebar accessory (above this band), so only the trailing
                    // (right-sidebar) edge needs to be ceded here.
                    //
                    // `rightSidebarWidth` is already `rightSidebarVisible ? fileExplorerWidth : 0`,
                    // so it collapses to 0 when the sidebar is hidden. The sidebar panel itself
                    // snaps without animation (`.transaction { $0.animation = nil }`), so we match
                    // that here — otherwise this inset could animate out of step with the panel on
                    // toggle and momentarily expose (or re-cover) the mode bar mid-transition.
                    .padding(.trailing, rightSidebarWidth)
                    .animation(nil, value: rightSidebarWidth)
            }
            .overlay(alignment: .topLeading) {
                if let placement = Self.fullscreenControlsPlacement(
                    isFullScreen: isFullScreen,
                    isSidebarVisible: sidebarState.isVisible
                ) {
                    fullscreenControls
                        .environment(
                            \.colorScheme,
                            sidebarState.isVisible
                                ? appearance.sidebarContentColorScheme
                                : appearance.chromeColorScheme
                        )
                        // Same vertical frame as the title row (`customTitlebar`)
                        // so the controls' center matches the folder icon / title.
                        .frame(height: max(1, WindowChromeMetrics.appTitlebarHeight - 2), alignment: .center)
                        .padding(.top, placement.topPadding)
                        .padding(.leading, placement.leadingPadding)
                }
            }
    }

    private func syncTrafficLightInset() {
        let inset: CGFloat = (isMinimalMode && !sidebarState.isVisible && !isFullScreen)
            ? CGFloat(titlebarDebugChromeSnapshot.trafficLightTabBarLeadingInset)
            : 0
        tabManager.syncWorkspaceTabBarLeadingInset(inset)
    }

    private func applyTitlebarDebugChromeChange() {
        if let observedWindow {
            AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
        }
        syncTrafficLightInset()
    }

    private func schedulePortalGeometrySynchronize() {
        if let observedWindow {
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
        } else {
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
        }
    }

    private func refreshWindowChromeMetrics(for window: NSWindow) {
        // Keep native measurements around for minimal WindowGroup safe-area cancellation.
        // Standard mode uses cmux's visual chrome height for layout.
        let computedTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let nextPadding = WindowChromeMetrics.clampedTitlebarHeight(computedTitlebarHeight)
        let nextSafeAreaTop = max(0, window.contentView?.safeAreaInsets.top ?? 0)
        if abs(titlebarPadding - nextPadding) > 0.5 {
            DispatchQueue.main.async {
                titlebarPadding = nextPadding
            }
        }
        if abs(hostingSafeAreaTop - nextSafeAreaTop) > 0.5 {
            DispatchQueue.main.async {
                hostingSafeAreaTop = nextSafeAreaTop
            }
        }
    }

    private func updateTitlebarText() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            if !titlebarText.isEmpty {
                titlebarText = ""
            }
            return
        }
        let title = tabManager.resolvedWorkspaceDisplayTitle(for: tab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if titlebarText != title {
            titlebarText = title
        }
    }

    private func scheduleTitlebarTextRefresh() {
        titlebarTextUpdateCoalescer.signal {
            updateTitlebarText()
        }
    }

    private func scheduleTitlebarThemeRefresh(
        reason: String,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousGeneration = titlebarThemeGeneration
        titlebarThemeGeneration &+= 1
        if GhosttyApp.shared.backgroundLogEnabled {
            let eventLabel = backgroundEventId.map(String.init) ?? "nil"
            let sourceLabel = backgroundSource ?? "nil"
            let payloadLabel = notificationPayloadHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh scheduled reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousGeneration=\(previousGeneration) generation=\(titlebarThemeGeneration) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        }
    }

    private func scheduleTitlebarThemeRefreshFromWorkspace(
        workspaceId: UUID,
        reason: String,
        backgroundEventId: UInt64?,
        backgroundSource: String?,
        notificationPayloadHex: String?
    ) {
        guard tabManager.selectedTabId == workspaceId else {
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh skipped workspace=\(workspaceId.uuidString) selected=\(tabManager.selectedTabId?.uuidString ?? "nil") reason=\(reason)"
            )
            return
        }

        scheduleTitlebarThemeRefresh(
            reason: reason,
            backgroundEventId: backgroundEventId,
            backgroundSource: backgroundSource,
            notificationPayloadHex: notificationPayloadHex
        )
    }

    private func resumeSession(entry: SessionEntry) {
        tabManager.resume(entry)
    }

    func openRightSidebarToolPane(_ mode: RightSidebarMode) {
        guard mode.canOpenAsPane,
              let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            NSSound.beep()
            return
        }

        sidebarSelectionState.selection = .tabs
        workspace.clearSplitZoom()
        _ = workspace.openOrFocusRightSidebarToolSurface(inPane: paneId, mode: mode, focus: true)
    }

    private func openFilePreviewFromSidebar(filePath: String) {
        guard let workspace = tabManager.selectedWorkspace else { return }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }

        sidebarSelectionState.selection = .tabs
        if workspace.isRemoteWorkspace {
            Task { [weak workspace, fileExplorerStore] in
                guard let workspace else { return }
                do {
                    let localURL = try await fileExplorerStore.materializeRemoteFileForPreview(path: filePath)
                    _ = workspace.openFileSurfaces(
                        inPane: paneId,
                        filePaths: [localURL.path],
                        focus: true,
                        reuseExisting: true
                    )
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        _ = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: true,
            reuseExisting: true
        )
    }

    private func syncFileExplorerDirectory() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            // No selection means we have no local cwd to scope by; clear so the
            // sessions panel doesn't keep filtering by a stale previous tab.
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }

        fileExplorerStore.showHiddenFiles = true

        if tab.isRemoteWorkspace {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            guard shouldSyncFileExplorerStore else {
                fileExplorerStore.applyWorkspaceRoot(.none)
                return
            }
            guard let config = tab.remoteConfiguration, config.transport == .ssh else {
                fileExplorerStore.applyWorkspaceRoot(.none)
                return
            }
            let unavailableDetail = tab.remoteConnectionDetail ?? tab.remoteDaemonStatus.detail

            #if DEBUG
            let hasUnavailableDetail = unavailableDetail?.isEmpty == false
            cmuxDebugLog(
                "fileExplorer.sync remote state=\(tab.remoteConnectionState.rawValue) " +
                "hasDestination=\(config.destination.isEmpty ? 0 : 1) " +
                "hasDisplayTarget=\(config.displayTarget.isEmpty ? 0 : 1) " +
                "hasIdentityFile=\(config.identityFile == nil ? 0 : 1) " +
                "hasDetail=\(hasUnavailableDetail ? 1 : 0)"
            )
            #endif

            fileExplorerStore.applyWorkspaceRoot(
                .remoteSSH(
                    workspaceId: tab.id,
                    connection: SSHFileExplorerConnection(
                        destination: config.destination,
                        port: config.port,
                        identityFile: config.identityFile,
                        sshOptions: config.sshOptions
                    ),
                    displayTarget: config.displayTarget,
                    rootPath: tab.currentDirectory,
                    isAvailable: tab.remoteConnectionState == .connected,
                    unavailableDetail: unavailableDetail
                )
            )
            return
        }

        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }

        sessionIndexStore.setCurrentDirectoryIfChanged(dir)
        guard shouldSyncFileExplorerStore else {
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }
        fileExplorerStore.applyWorkspaceRoot(.local(workspaceId: tab.id, path: dir))
    }

    private var shouldSyncFileExplorerStore: Bool {
        fileExplorerState.mode.shouldSyncFileExplorerStore(
            isRightSidebarVisible: fileExplorerState.isVisible
        )
    }

    private var focusedDirectory: String? {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return nil
        }
        // Use focused panel's directory if available
        if let focusedPanelId = tab.focusedPanelId,
           let panelDir = tab.panelDirectories[focusedPanelId] {
            let trimmed = panelDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    private func contentAndSidebarLayout(appearance: WindowAppearanceSnapshot) -> AnyView {
        let layout: AnyView
        // When matching terminal background, use HStack so both sidebar and terminal
        // sit directly on the window background with no intermediate layers.
        let useWithinWindow = sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue
            && !sidebarMatchTerminalBackground
        if useWithinWindow {
            // Overlay mode keeps the left sidebar on top, but the right
            // sidebar stays in an HStack so terminal rows are clipped before
            // the sidebar backdrop samples the window.
            layout = AnyView(
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        terminalContentWithSidebarDropOverlay(appearance: appearance)
                            .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                        rightSidebarPanelWithBackdrop(appearance: appearance)
                    }
                    if sidebarState.isVisible {
                        sidebarPanelWithBackdrop(appearance: appearance)
                    }
                }
            )
        } else {
            // Standard HStack mode for behindWindow blur
            layout = AnyView(
                HStack(spacing: 0) {
                    if sidebarState.isVisible {
                        sidebarPanelWithBackdrop(appearance: appearance)
                    }
                    terminalContentWithRightSidebarPanel(appearance: appearance)
                }
            )
        }

        return AnyView(
            layout
                .overlay(alignment: .leading) {
                    if sidebarState.isVisible {
                        sidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
                .overlay(alignment: .leading) {
                    if rightSidebarVisible {
                        rightSidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
        )
    }

    var body: some View {
        let appearance = windowAppearanceSnapshot
        var view = AnyView(
            ZStack(alignment: .topLeading) {
                WindowBackdropLayer(role: .windowRoot, snapshot: appearance)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                contentAndSidebarLayout(appearance: appearance)

                if !isMinimalMode {
                    workspaceTitlebarBand(appearance: appearance)
                        .zIndex(100)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth), minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight))
                .background(Color.clear)
                .background(
                    MinimalModeTitlebarEventSurfaceView(isEnabled: isMinimalMode && !isFullScreen)
                )
        )

        view = AnyView(view.onAppear {
            selectedWorkspaceDirectoryReading.wire(tabManager: tabManager)
            selectedWorkspaceDirectoryModel.wire(reading: selectedWorkspaceDirectoryReading)
            workspaceHandoffCoordinator.attach(host: tabManager)
            tabManager.applyWindowBackgroundForSelectedTab()
            workspaceHandoffCoordinator.reconcileMountedWorkspaceIds()
            workspaceHandoffCoordinator.seedPreviousSelection()
            installSidebarResizerPointerMonitorIfNeeded()
            let restoredWidth = normalizedSidebarWidth(sidebarState.persistedWidth)
            if abs(sidebarWidth - restoredWidth) > 0.5 {
                sidebarWidth = restoredWidth
            }
            if abs(sidebarState.persistedWidth - restoredWidth) > 0.5 {
                sidebarState.persistedWidth = restoredWidth
            }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)
            updateTitlebarText()
            syncTrafficLightInset()

            // Startup recovery (#399): if session restore or a race condition leaves the
            // view in a broken state (empty tabs, no selection, unmounted workspaces),
            // detect and recover after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak tabManager] in
                guard let tabManager else { return }
                var didRecover = false

                // Ensure there is at least one workspace.
                if tabManager.tabs.isEmpty {
                    tabManager.addWorkspace()
                    didRecover = true
                }

                // Ensure selectedTabId points to an existing workspace.
                if tabManager.selectedTabId == nil || !tabManager.tabs.contains(where: { $0.id == tabManager.selectedTabId }) {
                    tabManager.selectedTabId = tabManager.tabs.first?.id
                    didRecover = true
                }

                // Ensure mountedWorkspaceIds is populated.
                let mountedWorkspaceIds = workspaceHandoffCoordinator.mountedWorkspaceIds
                if mountedWorkspaceIds.isEmpty || !mountedWorkspaceIds.contains(where: { id in tabManager.tabs.contains { $0.id == id } }) {
                    workspaceHandoffCoordinator.reconcileMountedWorkspaceIds()
                    didRecover = true
                }

                // Ensure sidebar selection is valid.
                if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                    didRecover = true
                }

                syncSidebarSelectedWorkspaceIds()
                applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)

                if didRecover {
#if DEBUG
                    cmuxDebugLog("startup.recovery tabCount=\(tabManager.tabs.count) selected=\(tabManager.selectedTabId?.uuidString.prefix(8) ?? "nil") mounted=\(workspaceHandoffCoordinator.mountedWorkspaceIds.count)")
#endif
                    sentryBreadcrumb("startup.recovery", data: [
                        "tabCount": tabManager.tabs.count,
                        "selectedTabId": tabManager.selectedTabId?.uuidString ?? "nil",
                        "mountedCount": workspaceHandoffCoordinator.mountedWorkspaceIds.count
                    ])
                }
            }
        })

        view = AnyView(view.onChange(of: tabManager.selectedTabId) { newValue in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.view.selectedChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newValue))"
                )
            } else {
                cmuxDebugLog("ws.view.selectedChange id=none selected=\(debugShortWorkspaceId(newValue))")
            }
#endif
            tabManager.applyWindowBackgroundForSelectedTab()
            workspaceHandoffCoordinator.startWorkspaceHandoffIfNeeded(newSelectedId: newValue)
            workspaceHandoffCoordinator.reconcileMountedWorkspaceIds(selectedId: newValue)
            AppDelegate.shared?.syncBonsplitTabShortcutHintEligibility(in: observedWindow)
            guard let newValue else { return }
            if selectedTabIds.count <= 1 {
                selectedTabIds = [newValue]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == newValue }
            }
            updateTitlebarText()
        })

        view = AnyView(view.onChange(of: showModifierHoldHints) { _, _ in
            AppDelegate.shared?.syncBonsplitTabShortcutHintEligibility(in: observedWindow)
        })

        view = AnyView(view.onChange(of: selectedTabIds) { _ in
            syncSidebarSelectedWorkspaceIds()
        })

        // File explorer: keep the directory-change subscription stable across body re-evaluations.
        view = AnyView(view.onChange(of: selectedWorkspaceDirectoryModel.directoryChangeGeneration) { _ in
            syncFileExplorerDirectory()
        })

        view = AnyView(view.onChange(of: tabManager.isWorkspaceCycleHot) { _ in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.view.hotChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)"
                )
            } else {
                cmuxDebugLog("ws.view.hotChange id=none hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)")
            }
#endif
            workspaceHandoffCoordinator.reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onChange(of: workspaceHandoffCoordinator.retiringWorkspaceId) { _ in
            workspaceHandoffCoordinator.reconcileMountedWorkspaceIds()
        })

        // Prime background workspaces off-screen. Rendering them just to run a task
        // mounts every keepAllAlive tab view and can materialize hidden terminals.
        view = AnyView(view.task(id: backgroundWorkspacePrimeCoordinator.taskKey(for: tabManager)) {
            await backgroundWorkspacePrimeCoordinator.primePendingBackgroundWorkspaces(tabManager: tabManager)
        })

        // Observation-driven (the background-load sets moved to the
        // `@Observable BackgroundWorkspaceLoadModel`): reading the forwarders in
        // `body` registers a dependency, so `.onChange` fires on each genuine
        // change. The legacy `@Published` mutators already short-circuited
        // equal-set assignments, so `.onChange` matches the prior `.onReceive`
        // emission set exactly.
        view = AnyView(view.onChange(of: tabManager.debugPinnedWorkspaceLoadIds) { _ in
            workspaceHandoffCoordinator.reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onChange(of: tabManager.mountedBackgroundWorkspaceLoadIds) { _ in
            workspaceHandoffCoordinator.reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidSetTitle)) { notification in
            guard GhosttyTitleChange(notification: notification)?.tabId == tabManager.selectedTabId else { return }
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            let payloadHex = (notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString()
            let eventId = (notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value
            let source = notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String
            scheduleTitlebarThemeRefresh(
                reason: "ghosttyDefaultBackgroundDidChange",
                backgroundEventId: eventId,
                backgroundSource: source,
                notificationPayloadHex: payloadHex
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelectionState.selection = .tabs
            scheduleTitlebarTextRefresh()
        })

        // A grouped anchor's title-bar name is derived from its group's name, so
        // a group rename must refresh the cached titlebar text (#5404). Scope to
        // this view's `tabManager` (the notification's `object`) so a rename in
        // another window doesn't spuriously refresh this one.
        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .workspaceGroupNameDidChange, object: tabManager)) { _ in
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            refreshTmuxWorkspacePaneWindowOverlay(in: observedWindow)
            workspaceHandoffCoordinator.completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: tabId, reason: "focus")
            attemptCommandPaletteFocusRestoreIfNeeded()
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .workspacePaneGeometryDidChange)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            scheduleTmuxWorkspacePaneWindowOverlayGeometryRefresh(in: observedWindow)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .workspaceLayoutModeDidChange)) { notification in
            guard (notification.object as? Workspace)?.id == tabManager.selectedTabId else { return }
            refreshTmuxWorkspacePaneWindowOverlay(in: observedWindow)
        })

        view = AnyView(view.onChange(of: activePaneBorderColorHex) { _, _ in
            refreshTmuxWorkspacePaneWindowOverlay(in: observedWindow)
        })

        view = AnyView(view.onChange(of: titlebarThemeGeneration) { oldValue, newValue in
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh applied oldGeneration=\(oldValue) generation=\(newValue) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidBecomeFirstResponderSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            workspaceHandoffCoordinator.completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: tabId, reason: "first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedPanelId = selectedWorkspace.focusedPanelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: focusedPanelId,
                in: observedWindow ?? webView.window
            )
            workspaceHandoffCoordinator.completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: selectedTabId, reason: "browser_first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .webViewDidReceiveClick)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedBrowser = selectedWorkspace.panels.values.compactMap({ $0 as? BrowserPanel })
                    .first(where: { $0.webView === webView }) else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: focusedBrowser.id,
                in: observedWindow ?? webView.window
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  selectedWorkspace.focusedPanelId == panelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: panelId) else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: panelId,
                in: observedWindow ?? focusedBrowser.webView.window
            )
            workspaceHandoffCoordinator.completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: selectedTabId, reason: "browser_address_bar")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )) { _ in
            attemptCommandPaletteFocusRestoreIfNeeded()
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { notification in
            guard commandPalettePresentation.pendingTextSelectionBehavior != nil else { return }
            guard let editor = notification.object as? NSTextView,
                  editor.isFieldEditor else { return }
            guard let observedWindow else { return }
            guard editor.window === observedWindow else { return }
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onChange(of: isCommandPaletteSearchFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onChange(of: isCommandPaletteRenameFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        // Observe the `@Observable` workspace-id order instead of the retired
        // `tabsPublisher` Combine bridge. `.onReceive` replayed the current value
        // on appear, so `initial: true` reproduces that; the bridge fired during
        // the `tabs` willSet (new list, old storage), but this fires after the
        // change commits, so `tabManager.tabs` already reads the new list — the
        // value the closure used to receive as its parameter. The reconcile that
        // toggles portals (`setWorkspacePortalRenderingEnabled`) now also reads
        // the committed `tabs`, identical to the willSet-time `tabsPublisher.value`.
        view = AnyView(view.onChange(of: tabManager.tabs.map(\.id), initial: true) {
            let tabs = tabManager.tabs
            let existingIds = Set(tabs.map { $0.id })
            workspaceHandoffCoordinator.pruneRemovedWorkspaces(existingWorkspaceIds: existingIds)
            tabManager.pruneBackgroundWorkspaceLoads(existingIds: existingIds)
            workspaceHandoffCoordinator.reconcileMountedWorkspaceIds(orderedWorkspaceIds: tabs.map { $0.id })
            selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
            }
            if let lastIndex = lastSidebarSelectionIndex, lastIndex >= tabs.count {
                if let selectedId = tabManager.selectedTabId {
                    lastSidebarSelectionIndex = tabs.firstIndex { $0.id == selectedId }
                } else {
                    lastSidebarSelectionIndex = nil
                }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(tabs: tabs)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.stateDidChange)) { notification in
            let tabId = SidebarDragLifecycleNotification().tabId(from: notification)
            sidebarDraggedTabId = tabId
#if DEBUG
            cmuxDebugLog(
                "sidebar.dragState.content tab=\(debugShortWorkspaceId(tabId)) " +
                "reason=\(SidebarDragLifecycleNotification().reason(from: notification))"
            )
#endif
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteToggleRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            toggleCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            openCommandPaletteCommands()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSwitcherRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            openCommandPaletteSwitcher()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .defaultTerminalRegistrationDidChange)) { _ in
            refreshCachedDefaultTerminalStatus()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSubmitRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            handleCommandPaletteSubmitRequest()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteDismissRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            dismissCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameTabRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            openCommandPaletteRenameTabInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameWorkspaceRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            openCommandPaletteRenameWorkspaceInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteEditWorkspaceDescriptionRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            let shouldHandle = CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.request observed={\((observedWindow).commandPaletteWindowDebugSummary)} " +
                "requested={\((requestedWindow).commandPaletteWindowDebugSummary)} " +
                "shouldHandle=\(shouldHandle ? 1 : 0) presented=\(isCommandPalettePresented ? 1 : 0) " +
                "mode=\(commandPalettePresentation.mode.debugModeLabel)"
            )
#endif
            guard shouldHandle else { return }
            openCommandPaletteWorkspaceDescriptionInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteMoveSelection)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .commands = commandPalettePresentation.mode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
            moveCommandPaletteSelection(by: delta)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputInteractionRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPalettePresentation.mode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            handleCommandPaletteRenameInputInteraction()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputDeleteBackwardRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPalettePresentation.mode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            _ = handleCommandPaletteRenameDeleteBackward(modifiers: [])
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .feedbackComposerRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard CommandPaletteRequestWindowRoutingPolicy(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ).shouldHandle else { return }
            feedbackComposerCoordinator.present()
        })

        view = AnyView(view.background(WindowAccessor(dedupeByWindow: false) { window in
            // TODO(delta-merge): HEAD drives the tmux pane overlay through
            // tmuxWorkspacePaneOverlayRegistry; origin/main added a parallel
            // refreshTmuxWorkspacePaneWindowOverlay(...) path (WindowTmuxWorkspacePaneOverlayController)
            // that survives in auto-merged handlers. Reconcile onto one overlay controller.
            let tmuxOverlayState = tmuxWorkspacePaneWindowOverlayState(for: window)
            tmuxWorkspacePaneOverlayRegistry.controller(for: window, createIfNeeded: tmuxOverlayState != nil)?.update(state: tmuxOverlayState)
            let overlayController = WindowCommandPaletteOverlayController.installed(in: window)
            overlayController.update(isVisible: isCommandPalettePresented) { AnyView(commandPaletteOverlay) }
        }))

        view = AnyView(view.onChange(of: bgGlassTintHex) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onChange(of: bgGlassTintOpacity) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = true
            windowChrome.nativeTitlebarBackdropCoordinator.setTitlebarControlsHidden(
                true,
                in: window,
                isMinimalMode: isMinimalMode
            )
            AppDelegate.shared?.fullscreenControlsViewModel = fullscreenControlsViewModel
            syncTrafficLightInset()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = false
            windowChrome.nativeTitlebarBackdropCoordinator.setTitlebarControlsHidden(
                false,
                in: window,
                isMinimalMode: isMinimalMode
            )
            AppDelegate.shared?.fullscreenControlsViewModel = nil
            syncTrafficLightInset()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            let availableWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
            clampSidebarWidthIfNeeded(availableWidth: availableWidth)
            clampRightSidebarWidthIfNeeded(availableWidth: availableWidth)
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: rightSidebarMaxWidthSetting) { _, _ in
            clampRightSidebarWidthIfNeeded()
            if rightSidebarVisible {
                schedulePortalGeometrySynchronize()
            }
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarWidth) { _ in
            let sanitized = normalizedSidebarWidth(sidebarWidth)
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
                return
            }
            if abs(sidebarState.persistedWidth - sanitized) > 0.5 {
                sidebarState.persistedWidth = sanitized
            }
            // Sidebar width changes are pure SwiftUI layout updates, so portal-hosted
            // terminals and browsers need an explicit post-layout geometry resync.
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarMinimumWidthSetting) { _ in
            clampSidebarWidthIfNeeded()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: titlebarControlsStyleRawValue) { _ in
            clampSidebarWidthIfNeeded()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarState.isVisible) { _, isVisible in
            observedWindow?.setMinimalModeSidebarTitlebarControlsAvailable(isVisible)
            if let observedWindow {
                AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
            }
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: fileExplorerState.isVisible) { isVisible in
            if !isVisible {
                _ = AppDelegate.shared?.restoreTerminalFocusAfterRightSidebarHidden(in: observedWindow)
            }
            syncFileExplorerDirectory()
            if let observedWindow {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            }
        })

        view = AnyView(view.onChange(of: fileExplorerState.mode) { _, _ in
            syncFileExplorerDirectory()
        })

        view = AnyView(view.onChange(of: sidebarMatchTerminalBackground) { _ in
            tabManager.applyWindowBackdropModeForAllTabs(reason: "sidebarMatchTerminalBackgroundChanged")
            guard sidebarState.isVisible,
                  sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue else { return }
            schedulePortalGeometrySynchronize()
        })

        view = AnyView(view.onChange(of: isMinimalMode) { _, _ in
            if let observedWindow {
                windowChrome.nativeTitlebarBackdropCoordinator.setTitlebarControlsHidden(
                    isFullScreen,
                    in: observedWindow,
                    isMinimalMode: isMinimalMode
                )
                AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
                refreshWindowChromeMetrics(for: observedWindow)
                observedWindow.contentView?.needsLayout = true
                observedWindow.contentView?.superview?.needsLayout = true
                observedWindow.invalidateShadow()
            }
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: titlebarDebugChromeSnapshot) { _, _ in
            applyTitlebarDebugChromeChange()
        })

        view = AnyView(view.onChange(of: tabManager.tabs.map(\.id)) { _ in
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: sidebarState.persistedWidth) { newValue in
            let sanitized = normalizedSidebarWidth(newValue)
            if abs(newValue - sanitized) > 0.5 {
                sidebarState.persistedWidth = sanitized
                return
            }
            guard !sidebarResizerController.isResizerDragging else { return }
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
            }
        })

        view = AnyView(view.ignoresSafeArea())
        view = AnyView(view.sheet(isPresented: $feedbackComposerCoordinator.isPresented) {
            feedbackComposerCoordinator.composerSheet()
        })

        view = AnyView(view.onDisappear {
            if sidebarResizerController.isResizerDragging {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                sidebarResizerController.endDrag()
                sidebarResizerController.sidebarDragStartWidth = nil
            }
            removeSidebarResizerPointerMonitor()
        })

        let commandPaletteOverlayView = AnyView(commandPaletteOverlay)
        let appKitWindowMutationID = appearance.appKitWindowMutationID(
            windowBackgroundPolicy: windowChrome.windowBackgroundPolicy
        )
        let mainWindowAccessor = WindowAccessor(refreshID: appKitWindowMutationID) { [appearance, commandPaletteOverlayView] window in
            configureMainWindowChrome(
                window,
                appearance: appearance,
                commandPaletteOverlayView: commandPaletteOverlayView
            )
        }
        view = AnyView(view.background(mainWindowAccessor))

        return AnyView(view.cmuxAppearanceColorScheme(appearanceMode))
    }

    @MainActor
    private func configureMainWindowChrome(
        _ window: NSWindow,
        appearance: WindowAppearanceSnapshot,
        commandPaletteOverlayView: AnyView
    ) {
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.isRestorable = false
        window.setMinimalModeSidebarTitlebarControlsAvailable(sidebarState.isVisible)
        window.titlebarAppearsTransparent = true
        // Native AppKit titlebar dragging steals pane-tab drags in minimal
        // mode. Keep the main window immovable by default; explicit chrome
        // drag zones temporarily enable performDrag for real app moves.
        configureCmuxMainWindowDragBehavior(window)
        window.styleMask.insert(.fullSizeContentView)

        // Track this window for fullscreen notifications
        if observedWindow !== window {
            DispatchQueue.main.async {
                observedWindow = window
                isFullScreen = window.styleMask.contains(.fullScreen)
                let availableWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
                clampSidebarWidthIfNeeded(availableWidth: availableWidth)
                clampRightSidebarWidthIfNeeded(availableWidth: availableWidth)
                syncCommandPaletteDebugStateForObservedWindow()
                installSidebarResizerPointerMonitorIfNeeded()
                updateSidebarResizerBandState()
            }
        }

        refreshWindowChromeMetrics(for: window)
        // Keep content below the titlebar so drags on Bonsplit's tab bar don't
        // get interpreted as window drags.
        // User settings decide whether window glass is active. The native Tahoe
        // NSGlassEffectView path vs the older NSVisualEffectView fallback is chosen
        // inside WindowGlassEffect.apply.
        let backdropPlan = appearance.backdropPlan(
            glassEffectAvailable: windowChrome.glassEffect.isAvailable,
            windowBackgroundPolicy: windowChrome.windowBackgroundPolicy
        )
        windowChrome.nativeTitlebarBackdropCoordinator.removeNativeTitlebarBackdrop(in: window)
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1" {
            appEnvironment?.updateLog.append("ui test window accessor: id=\(windowIdentifier) visible=\(window.isVisible)")
        }
#endif
        let backdropResult = windowChrome.backdropController.apply(plan: backdropPlan, to: window)
        if backdropResult.didChangeGlassRoot {
            let tmuxOverlayState = tmuxWorkspacePaneWindowOverlayState(for: window)
            tmuxWorkspacePaneOverlayRegistry.controller(for: window, createIfNeeded: tmuxOverlayState != nil)?.update(state: tmuxOverlayState)
            WindowCommandPaletteOverlayController.installed(in: window)
                .update(isVisible: isCommandPalettePresented) { commandPaletteOverlayView }
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
            BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        }
        AppDelegate.shared?.attachUpdateAccessory(to: window)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        // Let cmux supply the translucent titlebar fills. AppKit's native
        // material otherwise blends a lighter strip over the terminal area.
        windowChrome.nativeTitlebarBackdropCoordinator.syncNativeTitlebarBackdrop(
            in: window,
            enabled: true,
            usesGlassStyle: backdropResult.usesWindowGlass
        )
        AppDelegate.shared?.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore
        )
        // TODO(delta-merge): origin/main added a WorkspacePortalRenderingPlan diff
        // optimization (lastReconciledPortalRenderingStatesByWorkspaceId) inside the
        // inline reconcileMountedWorkspaceIds. HEAD relocated reconcile to
        // WorkspaceHandoffCoordinator, which re-applies portal rendering for every
        // workspace each pass (same end state). Port the diff into the coordinator if
        // the redundant setPortalRenderingEnabled calls need trimming.
        AppFileDropTarget.installFileDropOverlayWhenReady(on: window, tabManager: tabManager)
    }

    private func addTab() {
        tabManager.addTab()
        sidebarSelectionState.selection = .tabs
    }

    private func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        windowChrome.backdropController.updateGlassTint(to: window, color: tintColor)
    }

    private var commandPaletteOverlay: some View {
        CommandPaletteOverlayView(
            presentation: commandPalettePresentation,
            onBackdropClick: { point in handleCommandPaletteBackdropClick(atContentPoint: point) },
            onDismiss: { dismissCommandPalette() },
            commandsContent: { commandPaletteCommandListView },
            renameInputContent: { target in
                CommandPaletteRenameInputView(
                    target: target,
                    presentation: commandPalettePresentation,
                    renameFocus: $isCommandPaletteRenameFocused,
                    onDeleteBackward: handleCommandPaletteRenameDeleteBackward(modifiers:),
                    onContinueRename: continueRenameFlow(target:),
                    onDismiss: { dismissCommandPalette() },
                    onInteraction: handleCommandPaletteRenameInputInteraction,
                    onAppearResetFocus: resetCommandPaletteRenameFocus
                )
            },
            renameConfirmContent: { target, proposedName in
                CommandPaletteRenameConfirmView(
                    target: target,
                    proposedName: proposedName,
                    onApplyRename: applyRenameFlow(target:proposedName:)
                )
            },
            workspaceDescriptionContent: { target, maxEditorHeight in
                CommandPaletteWorkspaceDescriptionInputView(
                    target: target,
                    maxEditorHeight: maxEditorHeight,
                    presentation: commandPalettePresentation,
                    shouldFocusEditor: $commandPaletteShouldFocusWorkspaceDescriptionEditor,
                    observedWindow: observedWindow,
                    onApplyWorkspaceDescription: applyWorkspaceDescriptionFlow(target:proposedDescription:),
                    onDismiss: { dismissCommandPalette() },
                    onAppearResetFocus: resetCommandPaletteWorkspaceDescriptionFocus
                )
            }
        )
    }

    private var commandPaletteCommandListView: some View {
        CommandPaletteCommandListView(
            presentation: commandPalettePresentation,
            isSearchFocused: Binding(get: { isCommandPaletteSearchFocused }, set: { isCommandPaletteSearchFocused = $0 }),
            placeholder: commandPaletteSearchPlaceholder,
            searchFingerprint: commandPaletteCurrentSearchFingerprint,
            onSubmit: runSelectedCommandPaletteResult,
            onEscape: { dismissCommandPalette() },
            onMoveSelection: moveCommandPaletteSelection(by:),
            onUnhandledNavigationKey: forwardCommandPaletteUnhandledNavigationKeyToFocusedTerminal,
            fieldEditorNavigationDelta: { commandSelector, event in
                commandPaletteSelectionDeltaForFieldEditorCommand(commandSelector, event: event)
            },
            keyEventNavigationDelta: { event in
                commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: event.modifierFlags,
                    chars: event.characters ?? event.charactersIgnoringModifiers ?? "",
                    keyCode: event.keyCode,
                    nextShortcut: KeyboardShortcutSettings.shortcutIfBound(for: .commandPaletteNext),
                    previousShortcut: KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious)
                )
            },
            shouldSubmitWithReturn: { event in
                CommandPaletteKeystroke(
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags,
                    characters: event.characters ?? event.charactersIgnoringModifiers ?? ""
                ).shouldSubmitWithReturn(mode: "single_line")
            },
            onAppearUpdateScrollTarget: {
                updateCommandPaletteScrollTarget(resultCount: commandPaletteCoordinator.visibleResults.count, animated: false)
            },
            onAppearResetSearchFocus: resetCommandPaletteSearchFocus,
            onQueryChange: handleCommandPaletteQueryChange(oldQuery:newQuery:),
            onSearchFingerprintChange: handleCommandPaletteSearchFingerprintChange,
            onResultsRevisionChange: handleCommandPaletteResultsRevisionChange,
            onSelectedResultIndexChange: handleCommandPaletteSelectedResultIndexChange,
            listContent: {
                CommandPaletteCommandListRenderView(
                    coordinator: commandPaletteCoordinator,
                    selectedRowBackground: cmuxAccentColor().opacity(0.12),
                    onRunResult: runCommandPaletteResult(commandID:)
                )
            }
        )
    }

    /// Applies the query-transition side effects (selection/scroll reset, optional
    /// results-pipeline reset, refresh scheduling, debug-state sync) when the
    /// command-list search field's query changes.
    private func handleCommandPaletteQueryChange(oldQuery: String, newQuery: String) {
        commandPaletteCoordinator.handleQueryChange(
            oldQuery: oldQuery,
            newQuery: newQuery,
            presentation: commandPalettePresentation,
            host: self
        )
    }

    /// Forces a corpus refresh after the search fingerprint changes, yielding one
    /// turn first so the query-state transition settles (otherwise the forced
    /// refresh can rebuild the old command list after deleting the ">" prefix).
    private func handleCommandPaletteSearchFingerprintChange() {
        commandPaletteCoordinator.handleSearchFingerprintChange(
            presentation: commandPalettePresentation,
            host: self
        )
    }

    /// Resolves the selected result index against the freshly materialized result
    /// IDs and re-syncs the selection anchor, scroll target, and debug state when
    /// the results revision advances.
    private func handleCommandPaletteResultsRevisionChange() {
        commandPaletteCoordinator.handleResultsRevisionChange(
            presentation: commandPalettePresentation,
            emptyStateText: commandPaletteEmptyStateText,
            host: self
        )
    }

    /// Retargets the scroll position and re-syncs the overlay command-list and
    /// debug state when the selected result index changes.
    private func handleCommandPaletteSelectedResultIndexChange() {
        commandPaletteCoordinator.handleSelectedResultIndexChange(
            presentation: commandPalettePresentation,
            emptyStateText: commandPaletteEmptyStateText,
            host: self
        )
    }

    private var commandPaletteListScope: CommandPaletteListScope {
        Self.commandPaletteQueryScopePolicy.listScope(for: commandPalettePresentation.query)
    }

    private var commandPaletteCurrentSearchFingerprint: Int {
        let scope = commandPaletteListScope
        return commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries,
            commandsContext: scope == .commands ? commandPaletteCachedCommandsContext() : nil
        )
    }

    /// Builds the switcher entries and fingerprints from a snapshot resolved by
    /// ``makeSwitcherSnapshot(includeSurfaces:)``. The view conforms to the
    /// snapshot seam, so the builder reads current live state on each call.
    private var commandPaletteSwitcherEntryBuilder: CommandPaletteSwitcherEntryBuilder {
        CommandPaletteSwitcherEntryBuilder(snapshotProvider: self)
    }

    static func commandPaletteShouldResetVisibleResultsForQueryTransition(
        oldQuery: String,
        newQuery: String,
        hasVisibleResults: Bool
    ) -> Bool {
        commandPaletteQueryScopePolicy.shouldResetVisibleResultsForQueryTransition(
            oldQuery: oldQuery,
            newQuery: newQuery,
            hasVisibleResults: hasVisibleResults
        )
    }

    nonisolated static func commandPaletteListIdentity(for query: String) -> String {
        commandPaletteQueryScopePolicy.listIdentity(for: query)
    }

    private var commandPaletteSwitcherIncludesSurfaceEntries: Bool {
        Self.commandPaletteQueryScopePolicy.switcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: commandPalettePresentation.query
        )
    }

    private var commandPaletteSearchPlaceholder: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsPlaceholder", defaultValue: "Type a command")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherPlaceholderAllSurfaces", defaultValue: "Search workspaces and surfaces")
                : String(localized: "commandPalette.search.switcherPlaceholder", defaultValue: "Search workspaces")
        }
    }

    private var commandPaletteEmptyStateText: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsEmpty", defaultValue: "No commands match your search.")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherEmptyAllSurfaces", defaultValue: "No workspaces or surfaces match your search.")
                : String(localized: "commandPalette.search.switcherEmpty", defaultValue: "No workspaces match your search.")
        }
    }

    private var commandPaletteQueryForMatching: String {
        Self.commandPaletteQueryScopePolicy.queryForMatching(
            query: commandPalettePresentation.query,
            scope: commandPaletteListScope
        )
    }

    nonisolated static func commandPaletteRefreshInputsForTests(
        stateQuery: String,
        observedQuery: String?,
        searchAllSurfaces: Bool
    ) -> (scope: String, matchingQuery: String, includesSurfaces: Bool) {
        let effectiveQuery = observedQuery ?? stateQuery
        let scope = commandPaletteQueryScopePolicy.listScope(for: effectiveQuery)
        return (
            scope: scope.rawValue,
            matchingQuery: commandPaletteQueryScopePolicy.queryForMatching(query: effectiveQuery, scope: scope),
            includesSurfaces: commandPaletteQueryScopePolicy.switcherIncludesSurfaceEntries(
                searchAllSurfaces: searchAllSurfaces,
                query: effectiveQuery
            )
        )
    }

    private func commandPaletteEntries(for scope: CommandPaletteListScope) -> [CommandPaletteCommand] {
        commandPaletteEntries(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries
        )
    }

    private func commandPaletteEntries(
        for scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        commandsContext: CommandPaletteCommandsContext? = nil
    ) -> [CommandPaletteCommand] {
        switch scope {
        case .commands:
            return commandPaletteCommands(commandsContext: commandsContext ?? commandPaletteCachedCommandsContext())
        case .switcher:
            return commandPaletteSwitcherEntryBuilder.switcherEntries(includeSurfaces: includeSurfaces)
        }
    }

    /// Builds the corpus-pipeline seam value the coordinator drives its corpus
    /// and nucleo-index build through. The closures keep the irreducible
    /// app-coupled work (entry building, forkable-agent availability,
    /// terminal-open targets, fingerprinting, results refresh) in the app
    /// target while ownership of the corpus/index state lives on the coordinator.
    private func commandPaletteSearchCorpusHost() -> CommandPaletteSearchCorpusHost {
        CommandPaletteSearchCorpusHost(
            isCommandPalettePresented: { isCommandPalettePresented },
            presentationQuery: { commandPalettePresentation.query },
            corpusBuildPlan: { scope, effectiveQuery in
                commandPaletteCorpusBuildPlan(for: scope, effectiveQuery: effectiveQuery)
            },
            corpusEntries: { plan in commandPaletteCorpusEntries(for: plan) },
            scheduleResultsRefresh: { query, preservePendingActivation in
                scheduleCommandPaletteResultsRefresh(
                    query: query,
                    preservePendingActivation: preservePendingActivation
                )
            }
        )
    }

    /// Resolves the corpus-build plan for `scope`, performing the unconditional
    /// per-refresh side effects (terminal-open targets, forkable-agent
    /// availability) before the coordinator's rebuild-skip decision, matching
    /// the legacy `refreshCommandPaletteSearchCorpus` ordering.
    private func commandPaletteCorpusBuildPlan(
        for scope: CommandPaletteListScope,
        effectiveQuery: String
    ) -> CommandPaletteSearchCorpusBuildPlan {
        let includeSurfaces = Self.commandPaletteQueryScopePolicy.switcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: effectiveQuery
        )
        let terminalOpenTargets = resolveCommandPaletteTerminalOpenTargets(for: scope)
        if commandPaletteTerminalOpenTargetAvailability != terminalOpenTargets {
            commandPaletteTerminalOpenTargetAvailability = terminalOpenTargets
        }
        refreshCommandPaletteForkableAgentAvailabilityIfNeeded(scope: scope)
        let commandsContext = scope == .commands
            ? commandPaletteCommandsContext(terminalOpenTargets: terminalOpenTargets)
            : nil
        let fingerprint = commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        return CommandPaletteSearchCorpusBuildPlan(
            scope: scope,
            includeSurfaces: includeSurfaces,
            fingerprint: fingerprint
        )
    }

    /// Materializes the live palette entries for a resolved corpus-build plan.
    private func commandPaletteCorpusEntries(
        for plan: CommandPaletteSearchCorpusBuildPlan
    ) -> [CommandPaletteCommand] {
        commandPaletteEntries(
            for: plan.scope,
            includeSurfaces: plan.includeSurfaces
        )
    }

    private func cancelCommandPaletteSearch() {
        commandPaletteCoordinator.cancelSearch()
    }

    private func cancelCommandPaletteSearchIndexBuild() {
        commandPaletteCoordinator.cancelSearchIndexBuild()
    }

    private func syncCommandPaletteOverlayCommandListState() {
        commandPaletteCoordinator.syncOverlayCommandListState(
            presentation: commandPalettePresentation,
            emptyStateText: commandPaletteEmptyStateText,
            shouldShowEmptyState: { commandPaletteShouldShowEmptyState }
        )
    }

    private func scheduleCommandPaletteResultsRefresh(
        query: String? = nil,
        forceSearchCorpusRefresh: Bool = false,
        preservePendingActivation: Bool = false
    ) {
        commandPaletteCoordinator.scheduleResultsRefresh(
            query: query,
            forceSearchCorpusRefresh: forceSearchCorpusRefresh,
            preservePendingActivation: preservePendingActivation,
            presentation: commandPalettePresentation,
            emptyStateText: commandPaletteEmptyStateText,
            corpusHost: commandPaletteSearchCorpusHost(),
            listHost: self
        )
    }

    private func commandPaletteEntriesFingerprint(for scope: CommandPaletteListScope) -> Int {
        commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries
        )
    }

    private func commandPaletteEntriesFingerprint(
        for scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        commandsContext: CommandPaletteCommandsContext? = nil
    ) -> Int {
        switch scope {
        case .commands:
            return commandPaletteSwitcherEntryBuilder.commandsFingerprint(
                commandsContext: commandsContext ?? commandPaletteCachedCommandsContext(),
                configRevision: cmuxConfigStore.configRevision
            )
        case .switcher:
            return commandPaletteSwitcherEntryBuilder.switcherEntriesFingerprint(
                includeSurfaces: includeSurfaces
            )
        }
    }

    /// Builds the switcher snapshot the package's
    /// ``CommandPaletteSwitcherEntryBuilder`` consumes. This is the irreducible
    /// live-state seam: it reads `TabManager`/`Workspace`/app-delegate state,
    /// resolves localized labels (app bundle) and display names, derives the
    /// searchable metadata, maps each panel type onto a keyword kind, and binds
    /// the per-row focus actions. The builder owns the resulting command/
    /// fingerprint structure.
    func makeSwitcherSnapshot(
        includeSurfaces: Bool
    ) -> [CommandPaletteSwitcherSnapshotWindow] {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        return windowContexts.map { context in
            let windowId = context.windowId
            let windowTabManager = context.tabManager
            let workspaces = commandPaletteOrderedSwitcherWorkspaces(for: context).map { workspace -> CommandPaletteSwitcherSnapshotWorkspace in
                let workspaceId = workspace.id
                let surfaces: [CommandPaletteSwitcherSnapshotSurface] = includeSurfaces
                    ? commandPaletteOrderedSwitcherPanels(for: workspace).compactMap { panelId in
                        guard let panel = workspace.panels[panelId] else { return nil }
                        return CommandPaletteSwitcherSnapshotSurface(
                            id: panelId,
                            displayName: panelDisplayName(
                                workspace: workspace,
                                panelId: panelId,
                                fallback: panel.displayTitle
                            ),
                            kindLabel: commandPaletteSurfaceKindLabel(for: panel.panelType),
                            keywordKind: Self.commandPaletteSurfaceKeywordKind(for: panel.panelType),
                            metadata: commandPaletteSurfaceSearchMetadata(for: workspace, panelId: panelId),
                            action: {
                                focusCommandPaletteSwitcherSurfaceTarget(
                                    windowId: windowId,
                                    tabManager: windowTabManager,
                                    workspaceId: workspace.id,
                                    panelId: panelId
                                )
                            }
                        )
                    }
                    : []
                return CommandPaletteSwitcherSnapshotWorkspace(
                    id: workspaceId,
                    displayName: workspaceDisplayName(workspace),
                    kindLabel: String(localized: "commandPalette.kind.workspace", defaultValue: "Workspace"),
                    subtitleBase: String(localized: "commandPalette.switcher.workspaceLabel", defaultValue: "Workspace"),
                    metadata: commandPaletteWorkspaceSearchMetadata(for: workspace),
                    surfaces: surfaces,
                    action: {
                        focusCommandPaletteSwitcherTarget(
                            windowId: windowId,
                            tabManager: windowTabManager,
                            workspaceId: workspaceId
                        )
                    }
                )
            }
            return CommandPaletteSwitcherSnapshotWindow(
                windowId: windowId,
                windowLabel: context.windowLabel,
                selectedWorkspaceId: context.selectedWorkspaceId,
                workspaces: workspaces
            )
        }
    }

    private func commandPaletteSwitcherWindowContexts() -> [CommandPaletteSwitcherWindowContext] {
        let fallback = CommandPaletteSwitcherWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            selectedWorkspaceId: tabManager.selectedTabId,
            windowLabel: nil
        )

        guard let windowRegistry = appEnvironment?.windowRegistry else { return [fallback] }
        let summaries = windowRegistry.listMainWindowSummaries()
        guard !summaries.isEmpty else { return [fallback] }

        let orderedSummaries = summaries.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.windowId == windowId
            let rhsIsCurrent = rhs.windowId == windowId
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        var windowLabelById: [UUID: String] = [:]
        if orderedSummaries.count > 1 {
            for (index, summary) in orderedSummaries.enumerated() where summary.windowId != windowId {
                windowLabelById[summary.windowId] = String(localized: "commandPalette.switcher.windowLabel", defaultValue: "Window \(index + 1)")
            }
        }

        var contexts: [CommandPaletteSwitcherWindowContext] = []
        var seenWindowIds: Set<UUID> = []
        for summary in orderedSummaries {
            guard let manager = windowRegistry.tabManagerFor(windowId: summary.windowId) else { continue }
            guard seenWindowIds.insert(summary.windowId).inserted else { continue }
            contexts.append(
                CommandPaletteSwitcherWindowContext(
                    windowId: summary.windowId,
                    tabManager: manager,
                    selectedWorkspaceId: summary.selectedWorkspaceId,
                    windowLabel: windowLabelById[summary.windowId]
                )
            )
        }

        if contexts.isEmpty {
            return [fallback]
        }
        return contexts
    }

    private func commandPaletteOrderedSwitcherWorkspaces(
        for context: CommandPaletteSwitcherWindowContext
    ) -> [Workspace] {
        var workspaces = context.tabManager.tabs
        guard !workspaces.isEmpty else { return [] }

        let selectedWorkspaceId = context.selectedWorkspaceId ?? context.tabManager.selectedTabId
        if let selectedWorkspaceId,
           let selectedIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceId }) {
            let selectedWorkspace = workspaces.remove(at: selectedIndex)
            workspaces.insert(selectedWorkspace, at: 0)
        }

        return workspaces
    }

    private func commandPaletteOrderedSwitcherPanels(for workspace: Workspace) -> [UUID] {
        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        guard orderedPanelIds.count < workspace.panels.count else { return orderedPanelIds }

        var panelIds = orderedPanelIds
        var seen = Set(orderedPanelIds)
        for panelId in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where seen.insert(panelId).inserted {
            panelIds.append(panelId)
        }
        return panelIds
    }

    private func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID
    ) {
        // Switcher commands dismiss the palette after action dispatch.
        // Defer focus mutation one turn so browser omnibar autofocus can run
        // without being blocked by the palette-visibility guard.
        DispatchQueue.main.async {
            _ = appEnvironment?.mainWindowRouter.focusMainWindow(windowId: windowId)
            tabManager.focusTab(
                workspaceId,
                suppressFlash: true,
                dismissRestoredUnreadOnResume: true
            )
        }
    }

    private func focusCommandPaletteSwitcherSurfaceTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID
    ) {
        DispatchQueue.main.async {
            _ = appEnvironment?.mainWindowRouter.focusMainWindow(windowId: windowId)
            tabManager.focusTab(
                workspaceId,
                surfaceId: panelId,
                suppressFlash: true,
                dismissRestoredUnreadOnResume: true
            )
        }
    }

    private func commandPaletteWorkspaceSearchMetadata(for workspace: Workspace) -> CommandPaletteSwitcherSearchMetadata {
        // Keep workspace rows coarse and stable for predictable workspace switching queries.
        let directories = [workspace.currentDirectory]
        let branches = [workspace.gitBranch?.branch].compactMap { $0 }
        let ports = workspace.listeningPorts
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports,
            description: workspace.customDescription
        )
    }

    private func commandPaletteSurfaceSearchMetadata(
        for workspace: Workspace,
        panelId: UUID
    ) -> CommandPaletteSwitcherSearchMetadata {
        let directories = [workspace.panelDirectories[panelId]].compactMap { $0 }
        let branches = [workspace.panelGitBranches[panelId]?.branch].compactMap { $0 }
        let ports = workspace.surfaceListeningPorts[panelId] ?? []
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }

    private func commandPaletteSurfaceKindLabel(for panelType: PanelType) -> String {
        switch panelType {
        case .terminal:
            return String(localized: "commandPalette.kind.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "commandPalette.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "commandPalette.kind.markdown", defaultValue: "Markdown")
        case .filePreview:
            return String(localized: "commandPalette.kind.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool:
            return String(localized: "commandPalette.kind.rightSidebarTool", defaultValue: "Tool")
        case .agentSession:
            return String(localized: "commandPalette.kind.agentSession", defaultValue: "Agent")
        case .project:
            return String(localized: "commandPalette.kind.project", defaultValue: "Project")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        case .customSidebar:
            return String(localized: "commandPalette.kind.customSidebar", defaultValue: "Custom Sidebar")
        }
    }

    private static func commandPaletteSurfaceKeywordKind(for panelType: PanelType) -> CommandPaletteSurfaceKeywordKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .extensionBrowser
        case .customSidebar:
            return .rightSidebarTool
        }
    }

    private func commandPaletteCachedCommandsContext() -> CommandPaletteCommandsContext {
        commandPaletteCommandsContext(
            terminalOpenTargets: commandPaletteTerminalOpenTargetAvailability
        )
    }

    private func resolveCommandPaletteTerminalOpenTargets(
        for scope: CommandPaletteListScope
    ) -> Set<TerminalDirectoryOpenTarget> {
        guard scope == .commands,
              focusedPanelContext?.panel.panelType == .terminal else {
            return []
        }
        return TerminalDirectoryOpenTarget.availableTargets()
    }

    static func commandPaletteForkableAgentPanelKey(workspaceId: UUID, panelId: UUID) -> String {
        CommandPaletteForkableAgentProbeCoordinator<ContentView>.panelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
    }

    typealias CommandPaletteForkSnapshotAvailability = CmuxCommandPalette.CommandPaletteForkSnapshotAvailability

    static func commandPaletteSnapshotForkAvailability(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool = false
    ) -> CommandPaletteForkSnapshotAvailability {
        snapshot.commandPaletteForkAvailability(isRemoteTerminal: isRemoteTerminal)
    }

    static func commandPaletteForkSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot
    ) -> String {
        snapshot.commandPaletteForkFingerprint
    }

    static func commandPaletteForkCacheFingerprint(
        snapshot: SessionRestorableAgentSnapshot,
        fallbackFingerprint: String?
    ) -> String {
        snapshot.commandPaletteForkCacheFingerprint(fallbackFingerprint: fallbackFingerprint)
    }

    static func commandPaletteForkableAgentProbeResultMatches(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool
    ) -> Bool {
        CommandPaletteForkableAgentProbeCoordinator<ContentView>.probeResultMatches(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    static func commandPaletteShouldReuseForkableAgentProbeResult(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool,
        cachedResultHadFallback: Bool,
        panelChanged: Bool
    ) -> Bool {
        CommandPaletteForkableAgentProbeCoordinator<ContentView>.shouldReuseProbeResult(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged
        )
    }

    static func commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool,
        cachedResultHadFallback: Bool,
        panelChanged: Bool
    ) -> Bool {
        CommandPaletteForkableAgentProbeCoordinator<ContentView>.shouldClearProbeResultBeforeProbe(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged
        )
    }

    static func commandPaletteForkMatchedFallbackProbeResultHadFallback(
        cachedResultHadFallback: Bool?
    ) -> Bool {
        CommandPaletteForkableAgentProbeCoordinator<ContentView>.matchedFallbackProbeResultHadFallback(
            cachedResultHadFallback: cachedResultHadFallback
        )
    }

    static func commandPalettePanelHasForkableAgent(
        workspaceId: UUID,
        panelId: UUID,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool] = [:],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteTerminal: Bool = false
    ) -> Bool {
        SessionRestorableAgentSnapshot.commandPalettePanelHasForkableAgent(
            panelKey: commandPaletteForkableAgentPanelKey(
                workspaceId: workspaceId,
                panelId: panelId
            ),
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            fallbackSnapshot: fallbackSnapshot,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    private func refreshCommandPaletteForkableAgentAvailabilityIfNeeded(scope: CommandPaletteListScope) {
        let panelContext: CommandPaletteForkableAgentPanelContext<SessionRestorableAgentSnapshot>?
        if scope == .commands,
           let focusedContext = focusedPanelContext,
           focusedContext.panel.panelType == .terminal {
            let workspaceId = focusedContext.workspace.id
            let panelId = focusedContext.panelId
            panelContext = CommandPaletteForkableAgentPanelContext(
                workspaceId: workspaceId,
                panelId: panelId,
                isRemoteTerminal: focusedContext.workspace.isRemoteTerminalSurface(panelId),
                fallbackSnapshot: focusedContext.workspace.restoredAgentSnapshotsByPanelId[panelId]
            )
        } else {
            panelContext = nil
        }
        commandPaletteForkableAgentProbeCoordinator.refreshAvailabilityIfNeeded(
            host: self,
            scopeIsCommands: scope == .commands,
            panelContext: panelContext
        )
    }

    private func cancelCommandPaletteForkableAgentAvailabilityProbe() {
        commandPaletteForkableAgentProbeCoordinator.cancelAllProbes()
    }

    private func cancelCommandPaletteForkableAgentAvailabilityProbe(for panelKey: String) {
        commandPaletteForkableAgentProbeCoordinator.cancelProbe(for: panelKey)
    }

    // MARK: - CommandPaletteForkableAgentProbeHost

    func commandPaletteForkSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot
    ) -> String {
        Self.commandPaletteForkSnapshotFingerprint(snapshot)
    }

    func commandPaletteSnapshotForkAvailability(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool
    ) -> CommandPaletteForkSnapshotAvailability {
        Self.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    func commandPaletteCurrentFallbackSnapshotFingerprint(
        workspaceId: UUID,
        panelId: UUID
    ) -> String? {
        guard let currentContext = focusedPanelContext,
              currentContext.workspace.id == workspaceId,
              currentContext.panelId == panelId,
              let currentFallbackSnapshot = currentContext.workspace.restoredAgentSnapshotsByPanelId[panelId] else {
            return nil
        }
        return Self.commandPaletteForkSnapshotFingerprint(currentFallbackSnapshot)
    }

    func commandPaletteProbeForkableAgentSupport(
        workspaceId: UUID,
        panelId: UUID,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteTerminal: Bool
    ) async -> CommandPaletteForkableAgentProbeResult<SessionRestorableAgentSnapshot> {
        let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
        // Matches the legacy in-host probe: short-circuit the expensive
        // capability probe (and its DEBUG log) once the probe task is cancelled.
        // The coordinator discards any result whose task is cancelled after this
        // returns, so the early result is never applied to the cache.
        guard !Task.isCancelled else {
            return CommandPaletteForkableAgentProbeResult(
                supportsFork: false,
                resolvedSnapshot: nil,
                usedFallbackSnapshot: false
            )
        }
        let indexSnapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId)
        let snapshot = indexSnapshot ?? fallbackSnapshot
        let supportsFork: Bool
        if let snapshot {
            supportsFork = await AgentForkSupport.supportsFork(
                snapshot: snapshot,
                isRemoteContext: isRemoteTerminal
            )
        } else {
            supportsFork = false
        }
#if DEBUG
        cmuxDebugLog(
            "palette.forkProbe panel=\(panelId.uuidString.prefix(5)) " +
                "indexSnapshot=\(indexSnapshot != nil ? 1 : 0) " +
                "fallbackSnapshot=\(fallbackSnapshot != nil ? 1 : 0) " +
                "kind=\(snapshot?.kind.rawValue ?? "none") " +
                "session=\(snapshot.map { String($0.sessionId.prefix(8)) } ?? "none") " +
                "launcher=\(snapshot?.launchCommand?.launcher ?? "none") " +
                "supportsFork=\(supportsFork ? 1 : 0)"
        )
#endif
        return CommandPaletteForkableAgentProbeResult(
            supportsFork: supportsFork,
            resolvedSnapshot: snapshot,
            usedFallbackSnapshot: indexSnapshot == nil && fallbackSnapshot != nil
        )
    }

    func commandPaletteRefreshResultsAfterForkableAgentProbe(activePanelKey: String) {
        guard isCommandPalettePresented else { return }
        scheduleCommandPaletteResultsRefresh(
            query: commandPalettePresentation.query,
            forceSearchCorpusRefresh: true
        )
    }

    private func refreshCachedDefaultTerminalStatus(refreshSearchCorpusIfPresented: Bool = true) {
        let isDefault = AppDelegate.defaultTerminalRegistrationStatus().isDefault
        guard cachedDefaultTerminalIsDefault != isDefault else { return }

        cachedDefaultTerminalIsDefault = isDefault
        commandPaletteCoordinator.invalidateSearchCorpusFingerprintCache()
        if refreshSearchCorpusIfPresented, isCommandPalettePresented {
            scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true, preservePendingActivation: true)
            syncCommandPaletteOverlayCommandListState()
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

    private func commandPaletteCommandsContext(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>
    ) -> CommandPaletteCommandsContext {
        let cliInstalledInPATH = AppDelegate.shared?.isCmuxCLIInstalledInPATH() ?? false
        var snapshot = commandPaletteContextSnapshot(terminalOpenTargets: terminalOpenTargets)
        snapshot.setBool(CommandPaletteContextKeys.cliInstalledInPATH, cliInstalledInPATH)
        snapshot.setBool(
            CommandPaletteContextKeys.defaultTerminalIsDefault,
            cachedDefaultTerminalIsDefault
        )
        return CommandPaletteCommandsContext(
            snapshot: snapshot
        )
    }

    private func commandPaletteCommands(
        commandsContext: CommandPaletteCommandsContext
    ) -> [CommandPaletteCommand] {
        let context = commandsContext.snapshot
        let contributions = commandPaletteCommandContributions()
        var handlerRegistry = CommandPaletteHandlerRegistry()
        registerCommandPaletteHandlers(&handlerRegistry)

        return CommandPaletteCommandListBuildPlan(
            contributions: contributions,
            context: context,
            resolveConfigOverride: { commandId in
                commandPaletteConfigActionID(for: commandId)
                    .flatMap { cmuxConfigStore.resolvedAction(id: $0) }
                    .map {
                        CommandPaletteConfigActionOverride(
                            palette: $0.palette,
                            title: $0.title,
                            subtitle: $0.subtitle,
                            keywords: $0.keywords
                        )
                    }
            },
            resolveShortcutHint: { contribution, context in
                commandPaletteShortcutHint(for: contribution, context: context)
            },
            resolveHandler: { handlerRegistry.handler(for: $0) },
            onMissingHandler: { commandId in
                assertionFailure("No command palette handler registered for \(commandId)")
            }
        ).commands
    }

    private func commandPaletteConfigActionID(for commandId: String) -> String? {
        switch commandId {
        case "palette.newTerminalTab":
            return CmuxSurfaceTabBarBuiltInAction.newTerminal.configID
        case "palette.newBrowserTab":
            return CmuxSurfaceTabBarBuiltInAction.newBrowser.configID
        case "palette.terminalSplitRight":
            return CmuxSurfaceTabBarBuiltInAction.splitRight.configID
        case "palette.terminalSplitDown":
            return CmuxSurfaceTabBarBuiltInAction.splitDown.configID
        default:
            return nil
        }
    }

    private func commandPaletteShortcutHint(
        for contribution: CommandPaletteCommandContribution,
        context: CommandPaletteContextSnapshot
    ) -> String? {
        if let configuredShortcut = cmuxConfigStore.resolvedAction(id: contribution.commandId)?.shortcut {
            return ShortcutDisplayFormatter().displayString(configuredShortcut)
        }
        if let configuredPaletteAction = commandPaletteConfigActionID(for: contribution.commandId),
           let configuredShortcut = cmuxConfigStore.resolvedAction(id: configuredPaletteAction)?.shortcut {
            return ShortcutDisplayFormatter().displayString(configuredShortcut)
        }
        if let action = Self.commandPaletteShortcutAction(forCommandID: contribution.commandId) {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard !shortcut.isUnbound else { return nil }
            guard action.shortcutContext.isAvailable(
                focusedBrowserPanel: context.bool(CommandPaletteContextKeys.panelIsBrowser),
                focusedMarkdownPanel: context.bool(CommandPaletteContextKeys.panelIsMarkdown),
                rightSidebarFocused: false
            ) else {
                return nil
            }
            return ShortcutDisplayFormatter().displayString(shortcut)
        }
        if let staticShortcut = CommandPaletteStaticShortcutHint(commandId: contribution.commandId).value {
            return staticShortcut
        }
        return contribution.shortcutHint
    }

    private func commandPaletteContextSnapshot(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>? = nil
    ) -> CommandPaletteContextSnapshot {
        var snapshot = CommandPaletteContextSnapshot()
        snapshot.setBool(CommandPaletteContextKeys.workspaceMinimalModeEnabled, isMinimalMode)
        snapshot.setBool(CommandPaletteContextKeys.sidebarMatchTerminalBackground, sidebarMatchTerminalBackground)
        snapshot.setBool(CommandPaletteContextKeys.browserDisabled, BrowserAvailabilitySettings.isDisabled())
        if let auth = appEnvironment?.auth {
            snapshot.setBool(CommandPaletteContextKeys.authSignedIn, auth.coordinator.isAuthenticated)
            snapshot.setBool(
                CommandPaletteContextKeys.authWorking,
                auth.coordinator.isLoading || auth.coordinator.isRestoringSession || auth.browserSignIn.isSigningIn
            )
        }

        if let workspace = tabManager.selectedWorkspace {
            let pinTarget = WorkspaceActionDispatcher.Target.single(workspace.id)
            let pinState = WorkspaceActionDispatcher.pinState(in: tabManager, target: pinTarget)
            snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
            snapshot.setString(CommandPaletteContextKeys.workspaceName, workspaceDisplayName(workspace))
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomName, workspace.customTitle != nil)
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomDescription, workspace.hasCustomDescription)
            snapshot.setBool(CommandPaletteContextKeys.workspaceShouldPin, pinState?.pinned ?? !workspace.isPinned)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasPullRequests,
                !workspace.sidebarPullRequestsInDisplayOrder().isEmpty
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasSplits,
                workspace.bonsplitController.allPaneIds.count > 1
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceCanvasLayout,
                workspace.layoutMode == .canvas
            )
            let workspaceIndex = tabManager.tabs.firstIndex { $0.id == workspace.id }
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasPeers, tabManager.tabs.count > 1)
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasAbove, (workspaceIndex ?? 0) > 0)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasBelow,
                (workspaceIndex ?? tabManager.tabs.count - 1) < tabManager.tabs.count - 1
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceCanMarkRead,
                sidebarUnread.canMarkWorkspaceRead(forWorkspaceIds: [workspace.id])
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceCanMarkUnread,
                sidebarUnread.canMarkWorkspaceUnread(forWorkspaceIds: [workspace.id])
            )
        }

        if let panelContext = focusedPanelContext {
            let workspace = panelContext.workspace
            let panelId = panelContext.panelId
            let panelIsTerminal = panelContext.panel.panelType == .terminal
            let panelIsRemoteTerminal = workspace.isRemoteTerminalSurface(panelId)
            snapshot.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            snapshot.setString(CommandPaletteContextKeys.panelName, panelDisplayName(workspace: workspace, panelId: panelId, fallback: panelContext.panel.displayTitle))
            snapshot.setBool(CommandPaletteContextKeys.panelIsBrowser, panelContext.panel.panelType == .browser)
            if let browserPanel = panelContext.panel as? BrowserPanel {
                snapshot.setBool(CommandPaletteContextKeys.panelBrowserFocusModeActive, browserPanel.isBrowserFocusModeActive)
            }
            // Markdown zoom only affects the rendered preview, so don't surface
            // the zoom commands when the panel is in raw text-edit mode.
            snapshot.setBool(
                CommandPaletteContextKeys.panelIsMarkdown,
                (panelContext.panel as? MarkdownPanel)?.displayMode == .preview
            )
            snapshot.setBool(
                CommandPaletteContextKeys.panelIsFilePreviewTextEditor,
                (panelContext.panel as? FilePreviewPanel)?.previewMode == .text
            )
            snapshot.setBool(
                CommandPaletteContextKeys.panelBrowserOmnibarVisible,
                (panelContext.panel as? BrowserPanel)?.isOmnibarVisible ?? true
            )
            snapshot.setBool(CommandPaletteContextKeys.panelIsTerminal, panelIsTerminal)
            snapshot.setBool(CommandPaletteContextKeys.panelHasPane, workspace.paneId(forPanelId: panelId) != nil)
            let fallbackForkableSnapshot = workspace.restoredAgentSnapshotsByPanelId[panelId]
            snapshot.setBool(
                CommandPaletteContextKeys.panelHasForkableAgent,
                Self.commandPalettePanelHasForkableAgent(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    supportedPanelKeys: commandPaletteForkableAgentProbeCoordinator.supportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentProbeCoordinator.remoteContextsByPanelKey,
                    fallbackSnapshot: fallbackForkableSnapshot,
                    isRemoteTerminal: panelIsRemoteTerminal
                )
            )
            snapshot.setBool(CommandPaletteContextKeys.panelHasCustomName, workspace.panelCustomTitles[panelId] != nil)
            snapshot.setBool(CommandPaletteContextKeys.panelShouldPin, !workspace.isPanelPinned(panelId))
            snapshot.setBool(CommandPaletteContextKeys.panelCanMoveToNewWorkspace, workspace.panels.count > 1)
            let hasUnread = workspace.manualUnreadPanelIds.contains(panelId) ||
                workspace.restoredUnreadPanelIds.contains(panelId) ||
                sidebarUnread.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: panelId)
            snapshot.setBool(CommandPaletteContextKeys.panelHasUnread, hasUnread)

            if panelIsTerminal {
                let availableTargets = terminalOpenTargets ?? TerminalDirectoryOpenTarget.availableTargets()
                for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
                    snapshot.setBool(
                        CommandPaletteContextKeys.terminalOpenTargetAvailable(target),
                        availableTargets.contains(target)
                    )
                }
            }
        }

        if case .updateAvailable = updateViewModel.effectiveState {
            snapshot.setBool(CommandPaletteContextKeys.updateHasAvailable, true)
        }

        return snapshot
    }

    /// Search keywords for the "Mobile Connect" command palette entry.
    ///
    /// Kept as a single source of truth so the contribution and its behavioral
    /// test agree on what queries (e.g. `ios`, `ipados`) must surface the
    /// command. These are platform/technical terms that read the same across
    /// locales, so they are not localized.
    static let commandPaletteMobileConnectKeywords: [String] = [
        "mobile", "connect", "pair", "pairing", "device",
        "ios", "ipados", "iphone", "ipad", "phone", "tablet", "qr",
    ]

    private func commandPaletteCommandContributions() -> [CommandPaletteCommandContribution] {
        let strings = commandPaletteContributionStrings()

        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            if let name = context.string(CommandPaletteContextKeys.workspaceName) {
                return strings.subtitle.workspaceNamed(name)
            }
            return strings.subtitle.workspaceFallback
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            if let name = context.string(CommandPaletteContextKeys.panelName) {
                return strings.subtitle.panelNamed(name)
            }
            return strings.subtitle.panelFallback
        }

        let hostBlocks = commandPaletteContributionHostBlocks(
            workspaceSubtitle: workspaceSubtitle,
            panelSubtitle: panelSubtitle
        )

        return CommandPaletteContributionProvider().build(
            strings: strings,
            hostBlocks: hostBlocks
        )
    }

    /// Resolves the static catalog's localized titles and subtitles against the
    /// app bundle (so Japanese and every other translation survives) and hands
    /// them to ``CommandPaletteContributionProvider``. The `String(localized:)`
    /// keys and default values are unchanged from the legacy inline builder.
    private func commandPaletteContributionStrings() -> CommandPaletteContributionStrings {
        CommandPaletteContributionStrings(
            subtitle: CommandPaletteContributionStrings.Subtitle(
                workspaceNamed: { name in
                    String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(name)")
                },
                workspaceFallback: String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace"))"),
                panelNamed: { name in
                    String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Tab • \(name)")
                },
                panelFallback: String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Tab • \(String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab"))"),
                browserNamed: { name in
                    String(localized: "commandPalette.subtitle.browserWithName", defaultValue: "Browser • \(name)")
                },
                browserFallback: String(localized: "commandPalette.subtitle.browserWithName", defaultValue: "Browser • \(String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab"))"),
                terminalNamed: { name in
                    String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(name)")
                },
                terminalFallback: String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab"))"),
                markdownNamed: { name in
                    String(localized: "commandPalette.subtitle.markdownWithName", defaultValue: "Markdown • \(name)")
                },
                markdownFallback: String(localized: "commandPalette.subtitle.markdownWithName", defaultValue: "Markdown • \(String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab"))")
            ),
            global: CommandPaletteContributionStrings.Global(
                newWorkspaceTitle: String(localized: "command.newWorkspace.title", defaultValue: "New Workspace"),
                newWorkspaceSubtitle: String(localized: "command.newWorkspace.subtitle", defaultValue: "Workspace"),
                newBrowserWorkspaceTitle: String(localized: "command.newBrowserWorkspace.title", defaultValue: "New Browser Workspace"),
                newBrowserWorkspaceSubtitle: String(localized: "command.newBrowserWorkspace.subtitle", defaultValue: "Workspace"),
                newWindowTitle: String(localized: "command.newWindow.title", defaultValue: "New Window"),
                newWindowSubtitle: String(localized: "command.newWindow.subtitle", defaultValue: "Window"),
                installCLITitle: String(localized: "command.installCLI.title", defaultValue: "Shell Command: Install 'cmux' in PATH"),
                installCLISubtitle: String(localized: "command.installCLI.subtitle", defaultValue: "CLI"),
                uninstallCLITitle: String(localized: "command.uninstallCLI.title", defaultValue: "Shell Command: Uninstall 'cmux' from PATH"),
                uninstallCLISubtitle: String(localized: "command.uninstallCLI.subtitle", defaultValue: "CLI"),
                openFolderTitle: String(localized: "command.openFolder.title", defaultValue: "Open Folder…"),
                openFolderSubtitle: String(localized: "command.openFolder.subtitle", defaultValue: "Workspace"),
                openFolderInVSCodeInlineTitle: String(localized: "command.openFolderInVSCodeInline.title", defaultValue: "Open Folder in VS Code (Inline)…"),
                openFolderInVSCodeInlineSubtitle: String(localized: "command.openFolderInVSCodeInline.subtitle", defaultValue: "VS Code Inline"),
                reopenPreviousSessionTitle: String(localized: "command.reopenPreviousSession.title", defaultValue: "Restore Previous App Launch"),
                reopenPreviousSessionSubtitle: String(localized: "command.reopenPreviousSession.subtitle", defaultValue: "History"),
                reopenClosedBrowserTabTitle: String(localized: "menu.history.reopenLastClosed", defaultValue: "Reopen Last Closed"),
                reopenClosedBrowserTabSubtitle: String(localized: "menu.history.title", defaultValue: "History"),
                openSettingsTitle: String(localized: "command.openSettings.title", defaultValue: "Open Settings"),
                openSettingsSubtitle: String(localized: "command.openSettings.subtitle", defaultValue: "Global"),
                openCmuxSettingsFileTitle: String(localized: "settings.settingsJSON.openFile", defaultValue: "Open cmux.json"),
                openCmuxSettingsFileSubtitle: String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"),
                openGhosttySettingsTitle: String(localized: "command.openGhosttySettings.title", defaultValue: "Open Ghostty Settings in TextEdit"),
                openGhosttySettingsSubtitle: String(localized: "command.openGhosttySettings.subtitle", defaultValue: "Ghostty Config Files"),
                mobileConnectTitle: String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad"),
                mobileConnectSubtitle: String(localized: "command.mobileConnect.subtitle", defaultValue: "Mobile"),
                makeDefaultTerminalTitle: String(localized: "command.makeDefaultTerminal.title", defaultValue: "Make cmux the Default Terminal"),
                makeDefaultTerminalSubtitle: String(localized: "command.makeDefaultTerminal.subtitle", defaultValue: "Global"),
                restartSocketListenerTitle: String(localized: "command.restartSocketListener.title", defaultValue: "Restart CLI Listener"),
                restartSocketListenerSubtitle: String(localized: "command.restartSocketListener.subtitle", defaultValue: "Global"),
                disableBrowserTitle: String(localized: "command.disableBrowser.title", defaultValue: "Disable cmux Browser"),
                disableBrowserSubtitle: String(localized: "command.browserAvailability.subtitle", defaultValue: "Browser"),
                enableBrowserTitle: String(localized: "command.enableBrowser.title", defaultValue: "Enable cmux Browser"),
                enableBrowserSubtitle: String(localized: "command.browserAvailability.subtitle", defaultValue: "Browser")
            ),
            layout: CommandPaletteContributionStrings.Layout(
                newTerminalTabTitle: String(localized: "command.newTerminalTab.title", defaultValue: "New Tab (Terminal)"),
                newTerminalTabSubtitle: String(localized: "command.newTerminalTab.subtitle", defaultValue: "Tab"),
                newBrowserTabTitle: String(localized: "command.newBrowserTab.title", defaultValue: "New Tab (Browser)"),
                newBrowserTabSubtitle: String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab"),
                closeTabTitle: String(localized: "command.closeTab.title", defaultValue: "Close Tab"),
                closeTabSubtitle: String(localized: "command.closeTab.subtitle", defaultValue: "Tab"),
                closeWorkspaceTitle: String(localized: "command.closeWorkspace.title", defaultValue: "Close Workspace"),
                closeWorkspaceSubtitle: String(localized: "command.closeWorkspace.subtitle", defaultValue: "Workspace"),
                closeWindowTitle: String(localized: "command.closeWindow.title", defaultValue: "Close Window"),
                closeWindowSubtitle: String(localized: "command.closeWindow.subtitle", defaultValue: "Window"),
                toggleFullScreenTitle: String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen"),
                toggleFullScreenSubtitle: String(localized: "command.toggleFullScreen.subtitle", defaultValue: "Window"),
                toggleSidebarTitle: String(localized: "command.toggleLeftSidebar.title", defaultValue: "Toggle Left Sidebar"),
                toggleSidebarSubtitle: String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout"),
                disableMatchTerminalBackgroundTitle: String(localized: "command.disableMatchTerminalBackground.title", defaultValue: "Disable Match Terminal Background"),
                enableMatchTerminalBackgroundTitle: String(localized: "command.enableMatchTerminalBackground.title", defaultValue: "Enable Match Terminal Background"),
                matchTerminalBackgroundSubtitle: String(localized: "command.matchTerminalBackground.subtitle", defaultValue: "Sidebar"),
                enableMinimalModeTitle: String(localized: "command.enableMinimalMode.title", defaultValue: "Enable Minimal Mode"),
                disableMinimalModeTitle: String(localized: "command.disableMinimalMode.title", defaultValue: "Disable Minimal Mode")
            ),
            notifications: CommandPaletteContributionStrings.Notifications(
                showNotificationsTitle: String(localized: "command.showNotifications.title", defaultValue: "Show Notifications"),
                showNotificationsSubtitle: String(localized: "command.showNotifications.subtitle", defaultValue: "Notifications"),
                jumpUnreadTitle: String(localized: "command.jumpUnread.title", defaultValue: "Jump to Latest Unread"),
                jumpUnreadSubtitle: String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications"),
                toggleUnreadTitle: String(localized: "command.toggleUnread.title", defaultValue: "Toggle Unread"),
                markOldestUnreadAndJumpNextTitle: String(localized: "command.markOldestUnreadAndJumpNext.title", defaultValue: "Mark as Oldest Unread and Jump to Next Latest Unread")
            ),
            updates: CommandPaletteContributionStrings.Updates(
                checkForUpdatesTitle: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
                checkForUpdatesSubtitle: String(localized: "command.checkForUpdates.subtitle", defaultValue: "Global"),
                applyUpdateIfAvailableTitle: String(localized: "command.applyUpdateIfAvailable.title", defaultValue: "Apply Update (If Available)"),
                applyUpdateIfAvailableSubtitle: String(localized: "command.applyUpdateIfAvailable.subtitle", defaultValue: "Global"),
                attemptUpdateTitle: String(localized: "command.attemptUpdate.title", defaultValue: "Attempt Update"),
                attemptUpdateSubtitle: String(localized: "command.attemptUpdate.subtitle", defaultValue: "Global")
            ),
            workspace: CommandPaletteContributionStrings.Workspace(
                renameTitle: String(localized: "command.renameWorkspace.title", defaultValue: "Rename Workspace…"),
                editDescriptionTitle: String(localized: "command.editWorkspaceDescription.title", defaultValue: "Edit Workspace Description…"),
                clearNameTitle: String(localized: "command.clearWorkspaceName.title", defaultValue: "Clear Workspace Name"),
                clearDescriptionTitle: String(localized: "command.clearWorkspaceDescription.title", defaultValue: "Clear Workspace Description"),
                pinTitle: String(localized: "command.pinWorkspace.title", defaultValue: "Pin Workspace"),
                unpinTitle: String(localized: "command.unpinWorkspace.title", defaultValue: "Unpin Workspace"),
                resetColorTitle: String(localized: "shortcut.resetWorkspaceColor.label", defaultValue: "Reset Workspace Color"),
                nextTitle: String(localized: "command.nextWorkspace.title", defaultValue: "Next Workspace"),
                nextSubtitle: String(localized: "command.nextWorkspace.subtitle", defaultValue: "Workspace Navigation"),
                previousTitle: String(localized: "command.previousWorkspace.title", defaultValue: "Previous Workspace"),
                previousSubtitle: String(localized: "command.previousWorkspace.subtitle", defaultValue: "Workspace Navigation"),
                moveUpTitle: String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
                moveDownTitle: String(localized: "contextMenu.moveDown", defaultValue: "Move Down"),
                moveToTopTitle: String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"),
                closeOtherTitle: String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces"),
                closeBelowTitle: String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below"),
                closeAboveTitle: String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above"),
                markReadTitle: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
                markUnreadTitle: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
                openPullRequestsTitle: String(localized: "command.openWorkspacePRLinks.title", defaultValue: "Open All Workspace PR Links"),
                openDiffViewerTitle: String(localized: "command.openDiffViewer.title", defaultValue: "Open Diff Viewer"),
                equalizeSplitsTitle: String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits")
            ),
            tab: CommandPaletteContributionStrings.Tab(
                renameTitle: String(localized: "command.renameTab.title", defaultValue: "Rename Tab…"),
                clearNameTitle: String(localized: "command.clearTabName.title", defaultValue: "Clear Tab Name"),
                pinTitle: String(localized: "command.pinTab.title", defaultValue: "Pin Tab"),
                unpinTitle: String(localized: "command.unpinTab.title", defaultValue: "Unpin Tab"),
                markReadTitle: String(localized: "command.markTabRead.title", defaultValue: "Mark Tab as Read"),
                markUnreadTitle: String(localized: "command.markTabUnread.title", defaultValue: "Mark Tab as Unread"),
                nextInPaneTitle: String(localized: "command.nextTabInPane.title", defaultValue: "Next Tab in Pane"),
                nextInPaneSubtitle: String(localized: "command.nextTabInPane.subtitle", defaultValue: "Tab Navigation"),
                previousInPaneTitle: String(localized: "command.previousTabInPane.title", defaultValue: "Previous Tab in Pane"),
                previousInPaneSubtitle: String(localized: "command.previousTabInPane.subtitle", defaultValue: "Tab Navigation")
            ),
            browser: CommandPaletteContributionStrings.Browser(
                backTitle: String(localized: "command.browserBack.title", defaultValue: "Back"),
                forwardTitle: String(localized: "command.browserForward.title", defaultValue: "Forward"),
                reloadTitle: String(localized: "command.browserReload.title", defaultValue: "Reload Page"),
                openDefaultTitle: String(localized: "command.browserOpenDefault.title", defaultValue: "Open Current Page in Default Browser"),
                focusAddressBarTitle: String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar"),
                enterFocusModeTitle: String(localized: "command.browserFocusMode.enter.title", defaultValue: "Enter Browser Focus Mode"),
                exitFocusModeTitle: String(localized: "command.browserFocusMode.exit.title", defaultValue: "Exit Browser Focus Mode"),
                showOmnibarTitle: String(localized: "command.browserShowOmnibar.title", defaultValue: "Show Browser Omnibar"),
                hideOmnibarTitle: String(localized: "command.browserHideOmnibar.title", defaultValue: "Hide Browser Omnibar"),
                toggleDevToolsTitle: String(localized: "command.browserToggleDevTools.title", defaultValue: "Toggle Developer Tools"),
                consoleTitle: String(localized: "command.browserConsole.title", defaultValue: "Show JavaScript Console"),
                reactGrabTitle: String(localized: "command.browserReactGrab.title", defaultValue: "Toggle React Grab"),
                zoomInTitle: String(localized: "command.browserZoomIn.title", defaultValue: "Zoom In"),
                zoomOutTitle: String(localized: "command.browserZoomOut.title", defaultValue: "Zoom Out"),
                zoomResetTitle: String(localized: "command.browserZoomReset.title", defaultValue: "Actual Size"),
                clearHistoryTitle: String(localized: "command.browserClearHistory.title", defaultValue: "Clear Browser History"),
                clearHistorySubtitle: String(localized: "command.browserClearHistory.subtitle", defaultValue: "Browser"),
                splitRightTitle: String(localized: "command.browserSplitRight.title", defaultValue: "Split Browser Right"),
                splitRightSubtitle: String(localized: "command.browserSplitRight.subtitle", defaultValue: "Browser Layout"),
                splitDownTitle: String(localized: "command.browserSplitDown.title", defaultValue: "Split Browser Down"),
                splitDownSubtitle: String(localized: "command.browserSplitDown.subtitle", defaultValue: "Browser Layout"),
                duplicateRightTitle: String(localized: "command.browserDuplicateRight.title", defaultValue: "Duplicate Browser to the Right"),
                duplicateRightSubtitle: String(localized: "command.browserDuplicateRight.subtitle", defaultValue: "Browser Layout")
            ),
            markdown: CommandPaletteContributionStrings.Markdown(
                zoomInTitle: String(localized: "command.markdownZoomIn.title", defaultValue: "Zoom In"),
                zoomOutTitle: String(localized: "command.markdownZoomOut.title", defaultValue: "Zoom Out"),
                zoomResetTitle: String(localized: "command.markdownZoomReset.title", defaultValue: "Actual Size")
            ),
            terminal: CommandPaletteContributionStrings.Terminal(
                vscodeServeWebStopTitle: String(localized: "command.vscodeServeWebStop.title", defaultValue: "Stop VS Code Inline Server"),
                vscodeServeWebRestartTitle: String(localized: "command.vscodeServeWebRestart.title", defaultValue: "Restart VS Code Inline Server"),
                findInDirectoryTitle: String(localized: "menu.find.findInDirectory", defaultValue: "Find in Directory…"),
                findInDirectorySubtitle: String(localized: "command.findInDirectory.subtitle", defaultValue: "Right Sidebar"),
                findTitle: String(localized: "command.terminalFind.title", defaultValue: "Find…"),
                findNextTitle: String(localized: "command.terminalFindNext.title", defaultValue: "Find Next"),
                findPreviousTitle: String(localized: "command.terminalFindPrevious.title", defaultValue: "Find Previous"),
                hideFindTitle: String(localized: "command.terminalHideFind.title", defaultValue: "Hide Find Bar"),
                useSelectionForFindTitle: String(localized: "command.terminalUseSelectionForFind.title", defaultValue: "Use Selection for Find"),
                toggleTextBoxInputTitle: String(localized: "command.terminalToggleTextBoxInput.title", defaultValue: "Toggle TextBox Input"),
                focusTextBoxInputTitle: String(localized: "command.terminalFocusTextBoxInput.title", defaultValue: "Focus TextBox Input"),
                attachTextBoxFileTitle: String(localized: "command.terminalAttachTextBoxFile.title", defaultValue: "Attach File to TextBox Input"),
                sendCtrlFTitle: String(localized: "command.terminalSendCtrlF.title", defaultValue: "Send Ctrl-F to Terminal"),
                clearScreenKeepScrollbackTitle: String(localized: "command.terminalClearScreenKeepScrollback.title", defaultValue: "Clear Screen (Keep Scrollback)")
            ),
            fork: CommandPaletteContributionStrings.Fork(
                rightTitle: String(localized: "command.forkAgentConversationRight.title", defaultValue: "Fork Conversation to the Right"),
                leftTitle: String(localized: "command.forkAgentConversationLeft.title", defaultValue: "Fork Conversation to the Left"),
                topTitle: String(localized: "command.forkAgentConversationTop.title", defaultValue: "Fork Conversation to the Top"),
                bottomTitle: String(localized: "command.forkAgentConversationBottom.title", defaultValue: "Fork Conversation to the Bottom"),
                newTabTitle: String(localized: "command.forkAgentConversationNewTab.title", defaultValue: "Fork Conversation to New Tab"),
                newWorkspaceTitle: String(localized: "command.forkAgentConversationNewWorkspace.title", defaultValue: "Fork Conversation to New Workspace")
            ),
            split: CommandPaletteContributionStrings.Split(
                terminalSplitRightTitle: String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right"),
                terminalSplitRightSubtitle: String(localized: "command.terminalSplitRight.subtitle", defaultValue: "Terminal Layout"),
                terminalSplitDownTitle: String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down"),
                terminalSplitDownSubtitle: String(localized: "command.terminalSplitDown.subtitle", defaultValue: "Terminal Layout"),
                terminalSplitBrowserRightTitle: String(localized: "command.terminalSplitBrowserRight.title", defaultValue: "Split Browser Right"),
                terminalSplitBrowserRightSubtitle: String(localized: "command.terminalSplitBrowserRight.subtitle", defaultValue: "Terminal Layout"),
                terminalSplitBrowserDownTitle: String(localized: "command.terminalSplitBrowserDown.title", defaultValue: "Split Browser Down"),
                terminalSplitBrowserDownSubtitle: String(localized: "command.terminalSplitBrowserDown.subtitle", defaultValue: "Terminal Layout"),
                toggleSplitZoomTitle: String(localized: "command.toggleSplitZoom.title", defaultValue: "Toggle Pane Zoom"),
                toggleSplitZoomSubtitle: String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout")
            )
        )
    }

    /// Builds the app-state-dependent contribution slices the package provider
    /// interleaves: extension-sidebar switches, right-sidebar/view/canvas/auth/
    /// settings-toggle commands, workspace-color commands, identifier-copy and
    /// move-tab commands, terminal directory open-targets, and cmux.json issue/
    /// custom-action commands. All localized text resolves here, app-side.
    private func commandPaletteContributionHostBlocks(
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        panelSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> CommandPaletteContributionHostBlocks {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func workspaceColorCommandTitle(_ paletteName: String) -> String {
            switch paletteName {
            case "Red":
                return String(localized: "shortcut.setWorkspaceColorRed.label", defaultValue: "Workspace Color: Red")
            case "Crimson":
                return String(localized: "shortcut.setWorkspaceColorCrimson.label", defaultValue: "Workspace Color: Crimson")
            case "Orange":
                return String(localized: "shortcut.setWorkspaceColorOrange.label", defaultValue: "Workspace Color: Orange")
            case "Amber":
                return String(localized: "shortcut.setWorkspaceColorAmber.label", defaultValue: "Workspace Color: Amber")
            case "Olive":
                return String(localized: "shortcut.setWorkspaceColorOlive.label", defaultValue: "Workspace Color: Olive")
            case "Green":
                return String(localized: "shortcut.setWorkspaceColorGreen.label", defaultValue: "Workspace Color: Green")
            case "Teal":
                return String(localized: "shortcut.setWorkspaceColorTeal.label", defaultValue: "Workspace Color: Teal")
            case "Aqua":
                return String(localized: "shortcut.setWorkspaceColorAqua.label", defaultValue: "Workspace Color: Aqua")
            case "Blue":
                return String(localized: "shortcut.setWorkspaceColorBlue.label", defaultValue: "Workspace Color: Blue")
            default:
                return String(
                    localized: "command.workspaceColor.named",
                    defaultValue: "Workspace Color: \(paletteName)"
                )
            }
        }

        // "Sidebar: <provider>" switch commands for each available view. The
        // built-in views are always offered; `descriptors` adds the hosted
        // extension sidebar only while the experimental Extensions beta is on.
        var extensionSidebar: [CommandPaletteCommandContribution] = []
        for descriptor in CmuxExtensionSidebarSelection().descriptors {
            let title = CmuxExtensionSidebarSelection().localizedTitle(for: descriptor)
            let titleFormat = String(localized: "command.switchExtensionSidebar.title", defaultValue: "Sidebar: %@")
            extensionSidebar.append(
                CommandPaletteCommandContribution(
                    commandId: CommandPaletteHashedCommandID(domain: .extensionSidebar, key: descriptor.id).value,
                    title: constant(String.localizedStringWithFormat(titleFormat, title)),
                    subtitle: constant(String(localized: "command.switchExtensionSidebar.subtitle", defaultValue: "Choose Sidebar")),
                    keywords: ["sidebar", "switch", "extension", title.lowercased()]
                )
            )
        }

        let makeDefaultTerminalKeywords = String(
            localized: "command.makeDefaultTerminal.keywords",
            defaultValue: "default,terminal,ssh,launch,services,handler,command,tool,executable"
        )
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        var workspaceColor: [CommandPaletteCommandContribution] = []
        for entry in WorkspaceTabColorSettings().palette() {
            workspaceColor.append(
                CommandPaletteCommandContribution(
                    commandId: CommandPaletteHashedCommandID(domain: .workspaceColor, key: entry.name).value,
                    title: constant(workspaceColorCommandTitle(entry.name)),
                    subtitle: workspaceSubtitle,
                    keywords: ["workspace", "color", "palette", entry.name.lowercased()],
                    when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
                )
            )
        }

        // TODO(delta-merge): HEAD relocated the palette command contributions to the
        // package CommandPaletteContributionProvider. origin/main also added a new
        // "palette.openDirectoryDiffViewer" contribution here that the package provider
        // does not yet carry (and it has no registered handler in this tree). Add that
        // command (contribution + handler) to the package to restore the feature.
        var terminalDirectoryOpenTargets: [CommandPaletteCommandContribution] = []
        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            terminalDirectoryOpenTargets.append(
                CommandPaletteCommandContribution(
                    commandId: target.commandPaletteCommandId,
                    title: constant(target.commandPaletteTitle),
                    subtitle: panelSubtitle,
                    keywords: target.commandPaletteKeywords,
                    when: { context in
                        context.bool(CommandPaletteContextKeys.panelIsTerminal)
                    }
                )
            )
        }

        let cmuxConfigDefaultSubtitle = String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json")
        var cmuxConfigIssues: [CommandPaletteCommandContribution] = []
        for issue in cmuxConfigStore.configurationIssues {
            cmuxConfigIssues.append(
                CommandPaletteCommandContribution(
                    commandId: CommandPaletteHashedCommandID(domain: .cmuxConfigIssue, key: issue.id).value,
                    title: constant(commandPaletteCmuxConfigIssueTitle(issue)),
                    subtitle: constant(commandPaletteCmuxConfigIssueSubtitle(issue)),
                    keywords: ["cmux", "config", "json", "schema", "error", "warning"]
                )
            )
        }
        var cmuxConfigCustomActions: [CommandPaletteCommandContribution] = []
        for action in cmuxConfigStore.paletteCustomActions() {
            let actionTitle = action.title.cmuxConfigPaletteSanitized
            let subtitleText = action.subtitle
                .map { $0.cmuxConfigPaletteSanitized }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? cmuxConfigDefaultSubtitle
            cmuxConfigCustomActions.append(
                CommandPaletteCommandContribution(
                    commandId: action.id,
                    title: constant(actionTitle),
                    subtitle: constant(subtitleText),
                    keywords: action.keywords
                )
            )
        }

        return CommandPaletteContributionHostBlocks(
            vscodeInlineAvailable: { TerminalDirectoryOpenTarget.vscodeInline.isAvailable() },
            extensionSidebar: extensionSidebar,
            rightSidebarMode: Self.commandPaletteRightSidebarModeCommandContributions(),
            rightSidebarToolPane: Self.commandPaletteRightSidebarToolPaneCommandContributions(),
            view: Self.commandPaletteViewCommandContributions(),
            canvas: Self.commandPaletteCanvasCommandContributions(),
            mobileConnectKeywords: Self.commandPaletteMobileConnectKeywords,
            makeDefaultTerminalKeywords: makeDefaultTerminalKeywords,
            auth: Self.commandPaletteAuthCommandContributions(),
            settingsToggle: Self.commandPaletteSettingsToggleCommandContributions(),
            workspaceColor: workspaceColor,
            identifierCopy: identifierCopyCommandContributions(
                workspaceSubtitle: workspaceSubtitle,
                panelSubtitle: panelSubtitle
            ),
            moveTabToNewWorkspace: moveTabToNewWorkspaceCommandContributions(panelSubtitle: panelSubtitle),
            terminalDirectoryOpenTargets: terminalDirectoryOpenTargets,
            cmuxConfigIssues: cmuxConfigIssues,
            cmuxConfigCustomActions: cmuxConfigCustomActions
        )
    }

    private func commandPaletteCmuxConfigIssueTitle(_ issue: CmuxConfigIssue) -> String {
        switch issue.kind {
        case .schemaError:
            return String(
                localized: "command.cmuxConfig.issue.schemaError.title",
                defaultValue: "cmux.json Schema Error"
            )
        default:
            return String(
                localized: "command.cmuxConfig.issue.warning.title",
                defaultValue: "cmux.json Configuration Warning"
            )
        }
    }

    private func commandPaletteCmuxConfigIssueSubtitle(_ issue: CmuxConfigIssue) -> String {
        let rawPath = issue.sourcePath.map {
            NSString(string: $0).abbreviatingWithTildeInPath
        } ?? issue.settingName
        let path = rawPath.cmuxConfigPaletteSanitized
        let detail = commandPaletteCmuxConfigIssueDetail(issue).cmuxConfigPaletteSanitized
        guard !detail.isEmpty else { return path }
        let format = String(
            localized: "command.cmuxConfig.issue.subtitle",
            defaultValue: "%@: %@"
        )
        return String(format: format, path, detail)
    }

    private func commandPaletteCmuxConfigIssueDetail(_ issue: CmuxConfigIssue) -> String {
        switch issue.kind {
        case .schemaError:
            let format = String(
                localized: "command.cmuxConfig.issue.schemaError.detail",
                defaultValue: "%@"
            )
            let fallback = String(
                localized: "command.cmuxConfig.issue.schemaError.fallback",
                defaultValue: "Invalid cmux.json"
            )
            return String(format: format, issue.message ?? fallback)
        case .newWorkspaceActionNotFound:
            let format = String(localized: "command.cmuxConfig.issue.newWorkspaceActionNotFound.detail", defaultValue: "%@ references missing action '%@'")
            return String(format: format, issue.settingName, issue.commandName ?? "")
        case .newWorkspaceCommandNotFound:
            let format = String(
                localized: "command.cmuxConfig.issue.newWorkspaceCommandNotFound.detail",
                defaultValue: "%@ references missing command '%@'"
            )
            return String(format: format, issue.settingName, issue.commandName ?? "")
        case .newWorkspaceCommandRequiresWorkspace:
            let format = String(
                localized: "command.cmuxConfig.issue.newWorkspaceCommandRequiresWorkspace.detail",
                defaultValue: "%@ '%@' must reference a workspace command"
            )
            return String(format: format, issue.settingName, issue.commandName ?? "")
        }
    }

    private func registerCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newWorkspace") {
            appEnvironment?.mainWindowRouter.performNewWorkspaceAction(
                tabManager: tabManager,
                debugSource: "palette.newWorkspace"
            )
        }
        registry.register(commandId: "palette.newBrowserWorkspace") {
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            DispatchQueue.main.async {
                _ = appEnvironment?.mainWindowRouter.performNewBrowserWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "palette.newBrowserWorkspace"
                )
            }
        }
        registry.register(commandId: "palette.openFolder") {
            // Defer so the command palette dismisses before the modal sheet appears.
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = String(localized: "panel.openFolder.title", defaultValue: "Open Folder")
                panel.prompt = String(localized: "panel.openFolder.prompt", defaultValue: "Open")
                if panel.runModal() == .OK, let url = panel.url {
                    tabManager.addWorkspace(workingDirectory: url.path)
                }
            }
        }
        registry.register(commandId: "palette.openFolderInVSCodeInline") {
            DispatchQueue.main.async {
                appEnvironment?.mainWindowRouter.showOpenFolderInInlineVSCodePanel(tabManager: tabManager)
            }
        }
        registry.register(commandId: "palette.reopenPreviousSession") {
            if AppDelegate.shared?.reopenPreviousSession() != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.newWindow") {
            guard let appDelegate = AppDelegate.shared else { return }
            let preferredWindow = appEnvironment?.windowRegistry.mainWindow(for: windowId)
            appDelegate.openNewMainWindow(preferredWindow: preferredWindow)
        }
        registry.register(commandId: "palette.installCLI") {
            AppDelegate.shared?.installCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.uninstallCLI") {
            AppDelegate.shared?.uninstallCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.newTerminalTab") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.newTerminal.configID) {
                tabManager.newSurface()
            }
        }
        registry.register(commandId: "palette.newBrowserTab") {
            if executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.newBrowser.configID) {
                return
            }
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.openBrowserAndFocusAddressBar()
            }
        }
        registry.register(commandId: "palette.closeTab") {
            tabManager.closeCurrentPanelWithConfirmation()
        }
        registry.register(commandId: "palette.closeWorkspace") {
            tabManager.closeCurrentWorkspaceWithConfirmation()
        }
        registry.register(commandId: "palette.closeWindow") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            if let appDelegate = AppDelegate.shared {
                appDelegate.closeWindowWithConfirmation(window)
            } else {
                window.performClose(nil)
            }
        }
        registry.register(commandId: "palette.toggleFullScreen") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.toggleFullScreen(nil)
        }
        registry.register(commandId: "palette.reopenClosedBrowserTab") {
            if let appDelegate = AppDelegate.shared {
                _ = appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: tabManager)
            } else {
                _ = tabManager.reopenMostRecentlyClosedItem()
            }
        }
        registry.register(commandId: "palette.toggleSidebar") {
            sidebarState.toggle()
        }
        // Register a handler for every possible view (including the hosted
        // extension sidebar) regardless of the beta flag, so a contribution that
        // was visible when the flag was on still resolves after a runtime flip.
        // Visibility is gated by `descriptors`; the handler set is the superset.
        for descriptor in CmuxExtensionSidebarSelection().allDescriptors {
            registry.register(commandId: CommandPaletteHashedCommandID(domain: .extensionSidebar, key: descriptor.id).value) {
                CmuxExtensionSidebarSelection().setProviderId(descriptor.id)
            }
        }
        for mode in RightSidebarMode.allCases {
            registry.register(commandId: Self.commandPaletteRightSidebarModeCommandID(mode)) {
                handleCommandPaletteRightSidebarMode(mode, observedWindow: observedWindow)
            }
        }
        for descriptor in Self.commandPaletteRightSidebarToolPaneCommandDescriptors() {
            registry.register(commandId: descriptor.commandId) {
                handleCommandPaletteRightSidebarToolPane(descriptor.mode)
            }
        }
        registry.register(commandId: "palette.toggleMatchTerminalBackground") {
            sidebarMatchTerminalBackground.toggle()
        }
        registry.register(commandId: "palette.enableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.minimal.rawValue
        }
        registry.register(commandId: "palette.disableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.standard.rawValue
        }
        registerViewCommandHandlers(&registry)
        registerCanvasCommandHandlers(&registry)
        registry.register(commandId: "palette.showNotifications") {
            AppDelegate.shared?.toggleNotificationsPopover(animated: false)
        }
        registry.register(commandId: "palette.jumpUnread") {
            AppDelegate.shared?.jumpToLatestUnread()
        }
        registry.register(commandId: "palette.toggleUnread") {
            AppDelegate.shared?.toggleFocusedNotificationUnread(
                preferredWindow: observedWindow
            )
        }
        registry.register(commandId: "palette.markOldestUnreadAndJumpNext") {
            AppDelegate.shared?.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                preferredWindow: observedWindow
            )
        }
        registry.register(commandId: "palette.openSettings") {
#if DEBUG
            cmuxDebugLog("palette.openSettings.invoke")
#endif
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "palette.openSettings")
            } else {
#if DEBUG
                cmuxDebugLog("palette.openSettings.missingAppDelegate fallback=1")
#endif
                AppDelegate.presentPreferencesWindow()
            }
        }
        registry.register(commandId: "palette.openCmuxSettingsFile") {
#if DEBUG
            cmuxDebugLog("palette.openCmuxSettingsFile.invoke")
#endif
            KeyboardShortcutSettings.openSettingsFileInEditor()
        }
        registry.register(commandId: "palette.openGhosttySettings") {
#if DEBUG
            cmuxDebugLog("palette.openGhosttySettings.invoke")
#endif
            ConfigSourceEnvironment.live().openInTextEditor()
        }
        registry.register(commandId: "palette.mobileConnect") {
#if DEBUG
            cmuxDebugLog("palette.mobileConnect.invoke")
#endif
            MobilePairingWindowController.shared.show()
        }
        registerAuthCommandHandlers(&registry)
        registry.register(commandId: "palette.makeDefaultTerminal") {
            AppDelegate.makeDefaultTerminal(debugSource: "palette.makeDefaultTerminal")
        }
        registry.register(commandId: "palette.checkForUpdates") {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        registry.register(commandId: "palette.applyUpdateIfAvailable") {
            AppDelegate.shared?.applyUpdateIfAvailable(nil)
        }
        registry.register(commandId: "palette.attemptUpdate") {
            AppDelegate.shared?.attemptUpdate(nil)
        }
        registry.register(commandId: "palette.restartSocketListener") {
            AppDelegate.shared?.restartSocketListener(nil)
        }
        registry.register(commandId: "palette.disableBrowser") {
            BrowserAvailabilitySettings.setDisabled(true)
        }
        registry.register(commandId: "palette.enableBrowser") {
            BrowserAvailabilitySettings.setDisabled(false)
        }
        registerSettingsToggleCommandHandlers(&registry)

        registry.register(commandId: "palette.renameWorkspace") {
            beginRenameWorkspaceFlow()
        }
        registry.register(commandId: "palette.editWorkspaceDescription") {
            beginWorkspaceDescriptionFlow()
        }
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomTitle(tabId: workspace.id)
        }
        registry.register(commandId: "palette.clearWorkspaceDescription") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomDescription(tabId: workspace.id)
        }
        registry.register(commandId: "palette.toggleWorkspacePin") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            let pinTarget = WorkspaceActionDispatcher.Target.single(workspace.id)
            guard WorkspaceActionDispatcher.performPinAction(in: tabManager, target: pinTarget) != nil else {
                NSSound.beep()
                return
            }
        }
        registry.register(commandId: "palette.resetWorkspaceColor") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.applyWorkspaceColor(nil, toWorkspaceIds: [workspace.id])
        }
        for entry in WorkspaceTabColorSettings().palette() {
            registry.register(commandId: CommandPaletteHashedCommandID(domain: .workspaceColor, key: entry.name).value) {
                guard let workspace = tabManager.selectedWorkspace else {
                    NSSound.beep()
                    return
                }
                tabManager.applyWorkspacePaletteColor(named: entry.name, toWorkspaceIds: [workspace.id])
            }
        }
        registry.register(commandId: "palette.nextWorkspace") {
            tabManager.selectNextTab()
        }
        registry.register(commandId: "palette.previousWorkspace") {
            tabManager.selectPreviousTab()
        }
        registry.register(commandId: "palette.moveWorkspaceUp") {
            moveSelectedWorkspace(by: -1)
        }
        registry.register(commandId: "palette.moveWorkspaceDown") {
            moveSelectedWorkspace(by: 1)
        }
        registry.register(commandId: "palette.moveWorkspaceToTop") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.moveTabsToTop([workspace.id])
            tabManager.selectWorkspace(workspace)
        }
        registry.register(commandId: "palette.closeOtherWorkspaces") {
            closeOtherSelectedWorkspaces()
        }
        registry.register(commandId: "palette.closeWorkspacesBelow") {
            closeSelectedWorkspacesBelow()
        }
        registry.register(commandId: "palette.closeWorkspacesAbove") {
            closeSelectedWorkspacesAbove()
        }
        registry.register(commandId: "palette.markWorkspaceRead") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markRead(forTabId: workspaceId)
        }
        registry.register(commandId: "palette.markWorkspaceUnread") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markUnread(forTabId: workspaceId)
        }
        registerIdentifierCopyCommandHandlers(&registry)

        registry.register(commandId: "palette.renameTab") {
            beginRenameTabFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.moveTabToNewWorkspace") {
            guard moveFocusedPanelToNewWorkspace() else { NSSound.beep(); return }
        }
        registry.register(commandId: "palette.toggleTabPin") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelPinned(
                panelId: panelContext.panelId,
                pinned: !panelContext.workspace.isPanelPinned(panelContext.panelId)
            )
        }
        registry.register(commandId: "palette.toggleTabUnread") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            let hasUnread = panelContext.workspace.manualUnreadPanelIds.contains(panelContext.panelId) ||
                panelContext.workspace.restoredUnreadPanelIds.contains(panelContext.panelId) ||
                sidebarUnread.hasUnreadNotification(forWorkspaceId: panelContext.workspace.id, surfaceId: panelContext.panelId)
            if hasUnread {
                panelContext.workspace.markPanelRead(panelContext.panelId)
            } else {
                panelContext.workspace.markPanelUnread(panelContext.panelId)
            }
        }
        registry.register(commandId: "palette.nextTabInPane") {
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            tabManager.selectPreviousSurface()
        }
        registry.register(commandId: "palette.openWorkspacePullRequests") {
            DispatchQueue.main.async {
                if !openWorkspacePullRequestsInConfiguredBrowser() {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.openDiffViewer") {
            if AppDelegate.shared?.openDiffViewerForFocusedWorkspace(for: tabManager) != true {
                NSSound.beep()
            }
        }

        registry.register(commandId: "palette.browserBack") {
            tabManager.focusedBrowserPanel?.goBack()
        }
        registry.register(commandId: "palette.browserForward") {
            tabManager.focusedBrowserPanel?.goForward()
        }
        registry.register(commandId: "palette.browserReload") {
            tabManager.focusedBrowserPanel?.reload()
        }
        registry.register(commandId: "palette.browserOpenDefault") {
            if !openFocusedBrowserInDefaultBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusAddressBar") {
            if !focusFocusedBrowserAddressBar() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusMode") {
            if !tabManager.toggleBrowserFocusModeForFocusedBrowser(reason: "commandPalette") {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleOmnibar") {
            if !tabManager.toggleOmnibarFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleDevTools") {
            if !tabManager.toggleDeveloperToolsFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserConsole") {
            if !tabManager.showJavaScriptConsoleFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserReactGrab") {
            if !tabManager.toggleReactGrabFromCurrentFocus() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomIn") {
            if !tabManager.zoomInFocusedBrowserOrTextFilePreview() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomOut") {
            if !tabManager.zoomOutFocusedBrowserOrTextFilePreview() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomReset") {
            if !tabManager.resetZoomFocusedBrowserOrTextFilePreview() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomIn") {
            if !tabManager.zoomInFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomOut") {
            if !tabManager.zoomOutFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomReset") {
            if !tabManager.resetZoomFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserClearHistory") {
            BrowserHistoryStore.shared.clearHistory()
        }
        registry.register(commandId: "palette.findInDirectory") {
            _ = appEnvironment?.mainWindowRouter.focusFileSearchInActiveWindow(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
        registry.register(commandId: "palette.browserSplitRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.browserSplitDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.browserDuplicateRight") {
            let url = tabManager.focusedBrowserPanel?.preferredURLStringForOmnibar().flatMap(URL.init(string:))
            _ = tabManager.createBrowserSplit(direction: .right, url: url)
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            registry.register(commandId: target.commandPaletteCommandId) {
                if !openFocusedDirectory(in: target) {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.vscodeServeWebStop") {
            stopInlineVSCodeServeWeb()
        }
        registry.register(commandId: "palette.vscodeServeWebRestart") {
            if !restartInlineVSCodeServeWeb() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFind") {
            tabManager.startSearch()
        }
        registry.register(commandId: "palette.terminalFindNext") {
            tabManager.findNext()
        }
        registry.register(commandId: "palette.terminalFindPrevious") {
            tabManager.findPrevious()
        }
        registry.register(commandId: "palette.terminalHideFind") {
            tabManager.hideFind()
        }
        registry.register(commandId: "palette.terminalUseSelectionForFind") {
            tabManager.searchSelection()
        }
        registry.register(commandId: "palette.terminalToggleTextBoxInput") {
            if !tabManager.toggleFocusedTerminalTextBox() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFocusTextBoxInput") {
            if !tabManager.focusFocusedTerminalTextBoxInputOrTerminal() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalAttachTextBoxFile") {
            if !tabManager.attachFileToFocusedTerminalTextBoxInput() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalSendCtrlF") {
            if !tabManager.sendCtrlFToFocusedTerminal() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalClearScreenKeepScrollback") {
            if !tabManager.clearFocusedTerminalKeepingScrollback() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalSplitRight") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.splitRight.configID) {
                tabManager.createSplit(direction: .right)
            }
        }
        registry.register(commandId: "palette.forkAgentConversationRight") {
            forkFocusedAgentConversationRight()
        }
        registry.register(commandId: "palette.forkAgentConversationLeft") {
            forkFocusedAgentConversationLeft()
        }
        registry.register(commandId: "palette.forkAgentConversationTop") {
            forkFocusedAgentConversationTop()
        }
        registry.register(commandId: "palette.forkAgentConversationBottom") {
            forkFocusedAgentConversationBottom()
        }
        registry.register(commandId: "palette.forkAgentConversationNewTab") {
            forkFocusedAgentConversationToNewTab()
        }
        registry.register(commandId: "palette.forkAgentConversationNewWorkspace") {
            forkFocusedAgentConversationToNewWorkspace()
        }
        registry.register(commandId: "palette.terminalSplitDown") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.splitDown.configID) {
                tabManager.createSplit(direction: .down)
            }
        }
        registry.register(commandId: "palette.terminalSplitBrowserRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitBrowserDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.toggleSplitZoom") {
            if !tabManager.toggleFocusedSplitZoom() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.equalizeSplits") {
            if let workspace = tabManager.selectedWorkspace, !tabManager.equalizeSplits(tabId: workspace.id) {
#if DEBUG
                cmuxDebugLog("palette.equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
#endif
            }
        }

        for issue in cmuxConfigStore.configurationIssues {
            let captured = issue
            registry.register(commandId: CommandPaletteHashedCommandID(domain: .cmuxConfigIssue, key: issue.id).value) {
                openCmuxConfigIssue(captured)
            }
        }
        for action in cmuxConfigStore.paletteCustomActions() {
            let captured = action
            registry.register(commandId: action.id) {
                executeConfiguredAction(captured)
            }
        }
    }

    private func openCmuxConfigIssue(_ issue: CmuxConfigIssue) {
        guard let sourcePath = issue.sourcePath,
              FileManager.default.fileExists(atPath: sourcePath) else {
            NSSound.beep()
            return
        }
        PreferredEditorService(defaults: .standard).open(URL(fileURLWithPath: sourcePath))
    }

    @discardableResult
    private func executeConfiguredAction(id: String) -> Bool {
        guard let action = cmuxConfigStore.resolvedAction(id: id) else {
            return false
        }
        return executeConfiguredAction(action)
    }

    @discardableResult
    private func executeConfiguredAction(_ action: CmuxResolvedConfigAction) -> Bool {
        let baseCwd = configuredActionBaseCwd()
        return CmuxConfigExecutor.execute(
            action: action,
            commands: cmuxConfigStore.loadedCommands,
            commandSourcePaths: cmuxConfigStore.commandSourcePaths,
            tabManager: tabManager,
            baseCwd: baseCwd,
            globalConfigPath: cmuxConfigStore.globalConfigPath
        )
    }

    private func configuredActionBaseCwd() -> String {
        tabManager.selectedWorkspace?.resolvedWorkingDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    private static func commandPaletteWorkspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : title
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        Self.commandPaletteWorkspaceDisplayName(workspace)
    }

    private func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? String(localized: "panel.displayName.fallback", defaultValue: "Tab") : trimmedFallback
    }

    private func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        commandPaletteCoordinator.clampedSelectedIndex(
            resultCount: resultCount,
            presentation: commandPalettePresentation
        )
    }

    private func updateCommandPaletteScrollTarget(resultCount: Int, animated: Bool) {
        commandPaletteCoordinator.updateScrollTarget(
            resultCount: resultCount,
            animated: animated,
            presentation: commandPalettePresentation,
            host: self
        )
    }

    private func syncCommandPaletteSelectionAnchor(resultIDs: [String]) {
        commandPaletteCoordinator.syncSelectionAnchor(
            resultIDs: resultIDs,
            presentation: commandPalettePresentation
        )
    }

    private func syncCommandPaletteSelectionAnchorFromCurrentResults() {
        commandPaletteCoordinator.syncSelectionAnchorFromCurrentResults(
            presentation: commandPalettePresentation
        )
    }

    private func syncCommandPaletteSelectionAnchorFromVisibleResults() {
        commandPaletteCoordinator.syncSelectionAnchorFromVisibleResults(
            presentation: commandPalettePresentation
        )
    }

    private func moveCommandPaletteSelection(by delta: Int) {
        commandPaletteCoordinator.moveSelection(
            by: delta,
            presentation: commandPalettePresentation,
            emptyStateText: commandPaletteEmptyStateText,
            host: self
        )
    }

    private func forwardCommandPaletteUnhandledNavigationKeyToFocusedTerminal(_ event: NSEvent) -> Bool {
        guard let target = commandPaletteRestoreFocusTarget,
              target.intent == .terminal(.surface),
              let workspace = tabManager.tabs.first(where: { $0.id == target.workspaceId }),
              let terminalPanel = workspace.panels[target.panelId] as? TerminalPanel else { return false }
        terminalPanel.hostedView.forwardKeyDownToSurface(event); return true
    }

    private func handleCommandPaletteRenameDeleteBackward(
        modifiers: EventModifiers
    ) -> BackportKeyPressResult {
        guard case .renameInput = commandPalettePresentation.mode else { return .ignored }
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return .ignored }

        if CommandPaletteRenameInputDeletePolicy(
            renameDraft: commandPalettePresentation.renameDraft,
            modifiers: modifiers
        ).shouldPopToCommands {
            commandPalettePresentation.mode = .commands
            resetCommandPaletteSearchFocus()
            syncCommandPaletteDebugStateForObservedWindow()
            return .handled
        }

        if let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.deleteBackward(nil)
            commandPalettePresentation.renameDraft = editor.string
        } else if !commandPalettePresentation.renameDraft.isEmpty {
            commandPalettePresentation.renameDraft.removeLast()
        }

        syncCommandPaletteDebugStateForObservedWindow()
        return .handled
    }

    private var commandPaletteHasCurrentResolvedResults: Bool {
        commandPaletteCoordinator.hasCurrentResolvedResults
    }

    private var commandPaletteShouldShowEmptyState: Bool {
        commandPaletteCoordinator.shouldShowEmptyState(presentation: commandPalettePresentation)
    }

    private func runCommandPaletteResolvedActivation(_ activation: CommandPaletteResolvedActivation) {
        switch activation {
        case .command(let commandID):
            guard let command = commandPaletteCoordinator.cachedResults.first(where: { $0.id == commandID })?.command else {
                return
            }
            runCommandPaletteCommand(command)
        case .selected(let fallbackIndex):
            guard !commandPaletteCoordinator.cachedResults.isEmpty else {
                NSSound.beep()
                return
            }
            let resolvedIndex = CommandPalettePendingActivation.resolvedSelectionIndex(
                preferredCommandID: commandPalettePresentation.selectionAnchorCommandID,
                fallbackSelectedIndex: fallbackIndex,
                resultIDs: commandPaletteCoordinator.cachedResults.map(\.id)
            )
            commandPalettePresentation.selectedResultIndex = resolvedIndex
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            runCommandPaletteCommand(commandPaletteCoordinator.cachedResults[resolvedIndex].command)
        }
    }

    private func runCommandPaletteResult(commandID: String) {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePresentation.pendingActivation = .command(
                    requestID: commandPaletteCoordinator.searchRequestID,
                    commandID: commandID
                )
            }
            return
        }
        runCommandPaletteResolvedActivation(.command(commandID: commandID))
    }

    private func runSelectedCommandPaletteResult() {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePresentation.pendingActivation = .selected(
                    requestID: commandPaletteCoordinator.searchRequestID,
                    fallbackSelectedIndex: commandPalettePresentation.selectedResultIndex,
                    preferredCommandID: commandPalettePresentation.selectionAnchorCommandID
                )
            }
            return
        }

        runCommandPaletteResolvedActivation(.selected(index: commandPalettePresentation.selectedResultIndex))
    }

    private func handleCommandPaletteSubmitRequest() {
        switch commandPalettePresentation.mode {
        case .commands:
            runSelectedCommandPaletteResult()
        case .renameInput(let target):
            continueRenameFlow(target: target)
        case .renameConfirm(let target, let proposedName):
            applyRenameFlow(target: target, proposedName: proposedName)
        case .workspaceDescriptionInput(let target):
#if DEBUG
            let newlineCount = commandPalettePresentation.workspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "palette.wsDescription.submit.request workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((commandPalettePresentation.workspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount)"
            )
#endif
            applyWorkspaceDescriptionFlow(
                target: target,
                proposedDescription: commandPalettePresentation.workspaceDescriptionDraft
            )
        }
    }

    private func runCommandPaletteCommand(_ command: CommandPaletteCommand) {
#if DEBUG
        cmuxDebugLog("palette.run commandId=\(command.id) dismissOnRun=\(command.dismissOnRun ? 1 : 0)")
#endif
        let postRunFocusTarget = commandPalettePostRunFocusTarget(for: command)
        commandPalettePresentation.recordUsage(command.id)
        let runPlan = CommandPaletteCommandRunPlan(
            dismissOnRun: command.dismissOnRun,
            dismissBeforeRun: CommandPaletteDismissBeforeRunPolicy(commandId: command.id).shouldDismissBeforeRun,
            hasFocusTarget: postRunFocusTarget != nil
        )
        for step in runPlan.steps {
            switch step {
            case .run:
                command.action()
            case .dismiss(let restoreFocus):
                if restoreFocus, let postRunFocusTarget {
                    dismissCommandPalette(restoreFocus: true, preferredFocusTarget: postRunFocusTarget)
                } else {
                    dismissCommandPalette(restoreFocus: false)
                }
            }
        }
    }

    private func commandPalettePostRunFocusTarget(for command: CommandPaletteCommand) -> CommandPaletteRestoreFocusTarget? {
        guard let intent = Self.commandPalettePostRunRestoreFocusIntent(forCommandId: command.id),
              let panelContext = focusedPanelContext else {
            return nil
        }
        return CommandPaletteRestoreFocusTarget(
            workspaceId: panelContext.workspace.id,
            panelId: panelContext.panelId,
            intent: intent
        )
    }

    private func toggleCommandPalette() {
        commandPaletteCoordinator.toggleCommandPaletteLifecycle(
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func openCommandPaletteCommands() {
        commandPaletteCoordinator.handleCommandPaletteListRequest(
            scope: .commands,
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func openCommandPaletteSwitcher() {
        commandPaletteCoordinator.handleCommandPaletteListRequest(
            scope: .switcher,
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func openCommandPaletteRenameTabInput() {
        commandPaletteEditFlowCoordinator.openRenameTabInput(
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func openCommandPaletteRenameWorkspaceInput() {
        requestSelectedWorkspaceInlineRename()
    }

    private func requestSelectedWorkspaceInlineRename() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }

        if isCommandPalettePresented {
            dismissCommandPalette(restoreFocus: false)
        }

        sidebarSelectionState.selection = .tabs
        selectedTabIds = [workspace.id]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == workspace.id }
        tabManager.selectWorkspace(workspace)
        sidebarInlineRenameWorkspaceId = workspace.id
        sidebarInlineRenameRequestToken += 1
    }

    private func openCommandPaletteWorkspaceDescriptionInput() {
#if DEBUG
        cmuxDebugLog(
            "palette.wsDescription.open begin presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(commandPalettePresentation.mode.debugModeLabel) " +
            "window={\((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow).commandPaletteWindowDebugSummary)}"
        )
#endif
        commandPaletteEditFlowCoordinator.openWorkspaceDescriptionInput(
            host: self,
            presentation: commandPalettePresentation
        )
#if DEBUG
        cmuxDebugLog(
            "palette.wsDescription.open end presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(commandPalettePresentation.mode.debugModeLabel) " +
            "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
    }

    static func commandPalettePostRunRestoreFocusIntent(forCommandId commandId: String) -> PanelFocusIntent? {
        switch commandId {
        case "palette.terminalFocusTextBoxInput",
             "palette.terminalAttachTextBoxFile":
            return .terminal(.textBoxInput)
        default:
            return nil
        }
    }

    private func syncCommandPaletteDebugStateForObservedWindow() {
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        AppDelegate.shared?.setCommandPaletteVisible(isCommandPalettePresented, for: window)
        let visibleResultCount = commandPaletteCoordinator.visibleResults.count
        let selectedIndex = isCommandPalettePresented ? commandPaletteSelectedIndex(resultCount: visibleResultCount) : 0
        AppDelegate.shared?.setCommandPaletteSelectionIndex(selectedIndex, for: window)
        AppDelegate.shared?.setCommandPaletteSnapshot(commandPaletteDebugSnapshot(), for: window)
    }

    private func commandPaletteDebugSnapshot() -> CommandPaletteDebugSnapshot {
        let mode: String
        switch commandPalettePresentation.mode {
        case .commands:
            mode = commandPaletteListScope.rawValue
        case .renameInput:
            mode = "rename_input"
        case .renameConfirm:
            mode = "rename_confirm"
        case .workspaceDescriptionInput:
            mode = "workspace_description_input"
        }

        return commandPaletteCoordinator.debugSnapshot(
            isPresented: isCommandPalettePresented,
            mode: mode,
            queryForMatching: commandPaletteQueryForMatching
        )
    }

    private func presentCommandPalette(initialQuery: String) {
        commandPaletteCoordinator.presentCommandPalette(
            initialQuery: initialQuery,
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func resetCommandPaletteListState(initialQuery: String) {
        commandPaletteCoordinator.resetCommandPaletteListState(
            initialQuery: initialQuery,
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func dismissCommandPalette(restoreFocus: Bool = true) {
        dismissCommandPalette(restoreFocus: restoreFocus, preferredFocusTarget: nil)
    }

    private func dismissCommandPalette(
        restoreFocus: Bool,
        preferredFocusTarget: CommandPaletteRestoreFocusTarget?
    ) {
        commandPaletteCoordinator.dismissCommandPalette(
            restoreFocus: restoreFocus,
            preferredFocusTarget: preferredFocusTarget,
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func handleCommandPaletteBackdropClick(atContentPoint contentPoint: CGPoint) {
        let clickedFocusTarget = commandPaletteBackdropFocusTarget(atContentPoint: contentPoint)
#if DEBUG
        if let clickedFocusTarget {
            cmuxDebugLog(
                "palette.dismiss.backdrop focusTarget panel=\(clickedFocusTarget.panelId.uuidString.prefix(5)) " +
                "workspace=\(clickedFocusTarget.workspaceId.uuidString.prefix(5)) intent=\(debugCommandPaletteFocusIntent(clickedFocusTarget.intent))"
            )
        } else {
            cmuxDebugLog("palette.dismiss.backdrop focusTarget=nil")
        }
#endif
        dismissCommandPalette(restoreFocus: true, preferredFocusTarget: clickedFocusTarget)
    }

    private func commandPaletteBackdropFocusTarget(atContentPoint contentPoint: CGPoint) -> CommandPaletteRestoreFocusTarget? {
        guard let window = observedWindow,
              let contentView = window.contentView else {
            return nil
        }

        let nsContentPoint = NSPoint(x: contentPoint.x, y: contentPoint.y)
        let windowPoint = contentView.convert(nsContentPoint, to: nil)
        return commandPaletteBackdropFocusTarget(atWindowPoint: windowPoint, in: window)
    }

    private func commandPaletteBackdropFocusTarget(
        atWindowPoint windowPoint: NSPoint,
        in window: NSWindow
    ) -> CommandPaletteRestoreFocusTarget? {
        let overlayController = WindowCommandPaletteOverlayController.installed(in: window)
        if let responder = overlayController.underlyingResponder(atWindowPoint: windowPoint),
           let target = commandPaletteBackdropFocusTarget(for: responder) {
            return target
        }

        if let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        if let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: window
            )
        }

        return nil
    }

    private func commandPaletteBackdropFocusTarget(for responder: NSResponder) -> CommandPaletteRestoreFocusTarget? {
        if let terminalView = cmuxOwningGhosttyView(for: responder),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: observedWindow
            )
        }

        if let webView = responder.commandPaletteOwningWebView,
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(for webView: WKWebView) -> CommandPaletteRestoreFocusTarget? {
        if let selectedWorkspace = tabManager.selectedWorkspace,
           let target = commandPaletteBrowserFocusTarget(in: selectedWorkspace, for: webView) {
            return target
        }

        let selectedWorkspaceId = tabManager.selectedTabId
        for workspace in tabManager.tabs where workspace.id != selectedWorkspaceId {
            if let target = commandPaletteBrowserFocusTarget(in: workspace, for: webView) {
                return target
            }
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(
        in workspace: Workspace,
        for webView: WKWebView
    ) -> CommandPaletteRestoreFocusTarget? {
        for (panelId, panel) in workspace.panels {
            guard let browserPanel = panel as? BrowserPanel,
                  browserPanel.webView === webView else {
                continue
            }

            return commandPaletteRestoreFocusTarget(
                workspaceId: workspace.id,
                panelId: panelId,
                fallbackIntent: .browser(.webView),
                in: observedWindow
            )
        }

        return nil
    }

    private func commandPaletteRestoreFocusTarget(
        workspaceId: UUID,
        panelId: UUID,
        fallbackIntent: PanelFocusIntent,
        in window: NSWindow?
    ) -> CommandPaletteRestoreFocusTarget {
        let intent = tabManager.tabs
            .first(where: { $0.id == workspaceId })?
            .panels[panelId]?
            .captureFocusIntent(in: window) ?? fallbackIntent

        return CommandPaletteRestoreFocusTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: intent
        )
    }

    /// Refreshes the focus-restore host's closures with this view value's live
    /// state so the long-lived `@State` controller calls back into the current
    /// view's `tabManager`/`observedWindow`/focused panel.
    private func wireCommandPaletteFocusRestoreHost() {
        commandPaletteFocusRestoreController.attach(commandPaletteFocusRestoreHost)
        commandPaletteFocusRestoreHost.isPaletteStillPresentedProvider = { isCommandPalettePresented }
        commandPaletteFocusRestoreHost.attemptHandler = { target in
            commandPaletteFocusRestoreAttempt(to: target)
        }
    }

    private func requestCommandPaletteFocusRestore(target: CommandPaletteRestoreFocusTarget) {
        wireCommandPaletteFocusRestoreHost()
        commandPaletteFocusRestoreController.request(target: target)
    }

    private func attemptCommandPaletteFocusRestoreIfNeeded() {
        wireCommandPaletteFocusRestoreHost()
        commandPaletteFocusRestoreController.attemptRestoreIfNeeded()
    }

    /// Drives one live focus-restore attempt and reports the outcome the
    /// controller's ``CommandPaletteFocusGuard`` consumes. Byte-faithful
    /// continuation of the previous inline `attemptCommandPaletteFocusRestoreIfNeeded`
    /// body; the palette-still-up and nil-target guards now live on the controller.
    private func commandPaletteFocusRestoreAttempt(
        to target: CommandPaletteRestoreFocusTarget
    ) -> CommandPaletteFocusRestoreOutcome {
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            return .targetUnavailable
        }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        tabManager.focusTab(
            target.workspaceId,
            surfaceId: target.panelId,
            suppressFlash: true,
            dismissRestoredUnreadOnResume: true
        )

        guard let context = focusedPanelContext,
              context.workspace.id == target.workspaceId,
              context.panelId == target.panelId else {
            return .retryLater
        }
        guard context.panel.restoreFocusIntent(target.intent) else { return .retryLater }
        return .restored
    }

#if DEBUG
    private func debugCommandPaletteFocusIntent(_ intent: PanelFocusIntent) -> String {
        switch intent {
        case .panel:
            return "panel"
        case .terminal(.surface):
            return "terminal.surface"
        case .terminal(.findField):
            return "terminal.findField"
        case .terminal(.textBoxInput):
            return "terminal.textBoxInput"
        case .browser(.webView):
            return "browser.webView"
        case .browser(.addressBar):
            return "browser.addressBar"
        case .browser(.findField):
            return "browser.findField"
        case .filePreview(.textEditor):
            return "filePreview.textEditor"
        case .filePreview(.pdfCanvas):
            return "filePreview.pdfCanvas"
        case .filePreview(.pdfThumbnails):
            return "filePreview.pdfThumbnails"
        case .filePreview(.pdfOutline):
            return "filePreview.pdfOutline"
        case .filePreview(.imageCanvas):
            return "filePreview.imageCanvas"
        case .filePreview(.mediaPlayer):
            return "filePreview.mediaPlayer"
        case .filePreview(.quickLook):
            return "filePreview.quickLook"
        case .project(.navigator):
            return "project.navigator"
        case .project(.detail):
            return "project.detail"
        }
    }
#endif

    private func resetCommandPaletteSearchFocus() {
        applyCommandPaletteInputFocusPolicy(.search)
    }

    private func resetCommandPaletteRenameFocus() {
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func resetCommandPaletteWorkspaceDescriptionFocus() {
#if DEBUG
        cmuxDebugLog(
            "palette.wsDescription.focus.reset schedule presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(commandPalettePresentation.mode.debugModeLabel) " +
            "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
        DispatchQueue.main.async {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.focus.reset apply.before search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "window={\((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow).commandPaletteWindowDebugSummary)} " +
                "fr=\(((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder).commandPaletteResponderDebugSummary)"
            )
#endif
            isCommandPaletteSearchFocused = false
            isCommandPaletteRenameFocused = false
            commandPaletteShouldFocusWorkspaceDescriptionEditor = true
            commandPalettePresentation.pendingTextSelectionBehavior = nil
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.focus.reset apply.after search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "fr=\(((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder).commandPaletteResponderDebugSummary)"
            )
#endif
        }
    }

    private func handleCommandPaletteRenameInputInteraction() {
        guard isCommandPalettePresented else { return }
        guard case .renameInput = commandPalettePresentation.mode else { return }
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func commandPaletteRenameInputFocusPolicy() -> CommandPaletteInputFocusPolicy {
        let selectAllOnFocus = CommandPaletteSettingsStore(defaults: .standard).renameSelectsAllOnFocus
        return CommandPaletteInputFocusPolicy.renameInput(selectsAllOnFocus: selectAllOnFocus)
    }

    private func applyCommandPaletteInputFocusPolicy(_ policy: CommandPaletteInputFocusPolicy) {
        DispatchQueue.main.async {
            commandPaletteShouldFocusWorkspaceDescriptionEditor = false
            switch policy.focusTarget {
            case .search:
                isCommandPaletteRenameFocused = false
                isCommandPaletteSearchFocused = true
            case .rename:
                isCommandPaletteSearchFocused = false
                isCommandPaletteRenameFocused = true
            }
            applyCommandPaletteTextSelection(policy.selectionBehavior)
        }
    }

    private func applyCommandPaletteTextSelection(_ behavior: CommandPaletteTextSelectionBehavior) {
        commandPalettePresentation.pendingTextSelectionBehavior = behavior
        attemptCommandPaletteTextSelectionIfNeeded()
    }

    private func attemptCommandPaletteTextSelectionIfNeeded() {
        guard isCommandPalettePresented else {
            commandPalettePresentation.pendingTextSelectionBehavior = nil
            return
        }
        // Pure mode/behavior gating lives on the package presentation model; the
        // field-editor lookup, the range application, and the post-apply clear
        // stay app-side. A `.skip` plan leaves the queued behavior pending for a
        // later focus, exactly as the legacy early-returns did.
        let plan = commandPalettePresentation.pendingTextSelectionPlan()
        guard plan != .skip else { return }
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        guard let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else {
            return
        }
        let length = (editor.string as NSString).length
        switch plan {
        case .skip:
            return
        case .selectAll:
            editor.setSelectedRange(NSRange(location: 0, length: length))
        case .caretAtEnd:
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
        commandPalettePresentation.pendingTextSelectionBehavior = nil
    }

    private func selectedWorkspaceIndex() -> Int? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return tabManager.tabs.firstIndex { $0.id == workspace.id }
    }

    private func moveSelectedWorkspace(by delta: Int) {
        guard let workspace = tabManager.selectedWorkspace,
              let currentIndex = selectedWorkspaceIndex() else { return }
        let targetIndex = currentIndex + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: targetIndex)
        tabManager.selectWorkspace(workspace)
    }

    private func closeWorkspaceIds(_ workspaceIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
    }

    private func closeOtherSelectedWorkspaces() {
        guard let workspace = tabManager.selectedWorkspace else { return }
        let workspaceIds = tabManager.tabs.compactMap { $0.id == workspace.id ? nil : $0.id }
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func closeSelectedWorkspacesBelow() {
        guard tabManager.selectedWorkspace != nil,
              let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.suffix(from: anchorIndex + 1).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func closeSelectedWorkspacesAbove() {
        guard tabManager.selectedWorkspace != nil,
              let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.prefix(upTo: anchorIndex).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func syncSidebarSelectedWorkspaceIds() {
        tabManager.setSidebarSelectedWorkspaceIds(selectedTabIds)
    }

    private func applyUITestSidebarSelectionIfNeeded(tabs: [Workspace]) {
#if DEBUG
        guard !didApplyUITestSidebarSelection else { return }
        let env = ProcessInfo.processInfo.environment
        guard let rawValue = env["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return
        }

        var indices: [Int] = []
        for token in rawValue.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = Int(trimmed), index >= 0 else { return }
            if !indices.contains(index) {
                indices.append(index)
            }
        }

        guard let lastIndex = indices.last, !indices.isEmpty, lastIndex < tabs.count else { return }

        let selectedIds = Set(indices.map { tabs[$0].id })
        selectedTabIds = selectedIds
        lastSidebarSelectionIndex = lastIndex
        tabManager.selectWorkspace(tabs[lastIndex])
        sidebarSelectionState.selection = .tabs
#if DEBUG
        UITestRecorder.record([
            "sidebarSelectedWorkspaceCount": String(selectedIds.count),
            "sidebarSelectedWorkspaceLastIndex": String(lastIndex),
            "sidebarWorkspaceCount": String(tabs.count),
        ])
#endif
        didApplyUITestSidebarSelection = true
#endif
    }

    private func beginRenameWorkspaceFlow() {
        requestSelectedWorkspaceInlineRename()
    }

    private func beginWorkspaceDescriptionFlow() {
        commandPaletteEditFlowCoordinator.beginWorkspaceDescription(
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func beginRenameTabFlow() {
        commandPaletteEditFlowCoordinator.beginRenameTab(
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func continueRenameFlow(target: CommandPaletteRenameTarget) {
        commandPaletteEditFlowCoordinator.continueRename(
            target: target,
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func applyRenameFlow(target: CommandPaletteRenameTarget, proposedName: String) {
        commandPaletteEditFlowCoordinator.applyRename(
            target: target,
            proposedName: proposedName,
            host: self,
            presentation: commandPalettePresentation
        )
    }

    private func applyWorkspaceDescriptionFlow(
        target: CommandPaletteWorkspaceDescriptionTarget,
        proposedDescription: String
    ) {
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            NSSound.beep()
            return
        }
#if DEBUG
        let newlineCount = proposedDescription.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        cmuxDebugLog(
            "palette.wsDescription.apply.begin workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "proposedLen=\((proposedDescription as NSString).length) " +
            "newlines=\(newlineCount) " +
            "text=\"\((proposedDescription).commandPaletteDebugPreview())\""
        )
#endif
        tabManager.setCustomDescription(tabId: target.workspaceId, description: proposedDescription)
#if DEBUG
        if let updatedWorkspace = tabManager.tabs.first(where: { $0.id == target.workspaceId }) {
            let persisted = updatedWorkspace.customDescription ?? ""
            let persistedNewlineCount = persisted.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "palette.wsDescription.apply.end workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "persistedLen=\((persisted as NSString).length) " +
                "persistedNewlines=\(persistedNewlineCount) " +
                "text=\"\((persisted).commandPaletteDebugPreview())\""
            )
        }
#endif
        dismissCommandPalette()
    }

    private func focusFocusedBrowserAddressBar() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel else { return false }
        _ = panel.requestAddressBarFocus(selectionIntent: .selectAll)
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
        return true
    }

    private func openFocusedBrowserInDefaultBrowser() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel,
              let rawURL = panel.preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func openWorkspacePullRequestsInConfiguredBrowser() -> Bool {
        guard let workspace = tabManager.selectedWorkspace else { return false }
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        guard !pullRequests.isEmpty else { return false }

        var openedCount = 0
        if BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser() {
            for pullRequest in pullRequests {
                if tabManager.openBrowser(url: pullRequest.url, insertAtEnd: true) != nil {
                    openedCount += 1
                } else if NSWorkspace.shared.open(pullRequest.url) {
                    openedCount += 1
                }
            }
            return openedCount > 0
        }

        for pullRequest in pullRequests {
            if NSWorkspace.shared.open(pullRequest.url) {
                openedCount += 1
            }
        }
        return openedCount > 0
    }

    private func openFocusedDirectory(in target: TerminalDirectoryOpenTarget) -> Bool {
        guard let directoryURL = focusedTerminalDirectoryURL() else { return false }
        return openFocusedDirectory(directoryURL, in: target)
    }

    private func openFocusedDirectory(_ directoryURL: URL, in target: TerminalDirectoryOpenTarget) -> Bool {
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            return true
        case .vscodeInline:
            return openFocusedDirectoryInInlineVSCode(directoryURL)
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
    }

    private func openFocusedDirectoryInInlineVSCode(_ directoryURL: URL) -> Bool {
        AppDelegate.shared?.openDirectoryInInlineVSCode(directoryURL, tabManager: tabManager) ?? false
    }

    private func stopInlineVSCodeServeWeb() {
        appEnvironment?.vscodeServeWebController.stop()
    }

    private func restartInlineVSCodeServeWeb() -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }
        appEnvironment?.vscodeServeWebController.restart(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            if serveWebURL == nil {
                NSSound.beep()
            }
        }
        return true
    }

    private func focusedTerminalDirectoryURL() -> URL? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let rawDirectory: String = {
            if let focusedPanelId = workspace.focusedPanelId,
               let directory = workspace.panelDirectories[focusedPanelId] {
                return directory
            }
            return workspace.currentDirectory
        }()
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

#if DEBUG
    private func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private func debugShortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }

    private func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif
}

// `SidebarTabItemSettingsSnapshot` is a pure value type that now lives in the
// `CmuxSidebar` package. Its `UserDefaults`/`SettingCatalog`-reading construction
// stays app-side here as a factory init that reads the app's defaults and folds
// the result into the moved memberwise value.
extension SidebarTabItemSettingsSnapshot {
    init(
        defaults: UserDefaults = .standard,
        sidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize
    ) {
        let sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
        let sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
        let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
        let sidebarFontScale = SidebarTabItemFontScale.scale(for: sidebarFontSize)
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let showsGitBranch = Self.bool(defaults: defaults, key: "sidebarShowGitBranch", defaultValue: true)
        let usesVerticalBranchLayout = settings.value(for: catalog.sidebar.branchVerticalLayout)
        let stacksBranchAndDirectory = settings.value(for: catalog.sidebar.stackBranchDirectory)
        let usesLastSegmentPath = settings.value(for: catalog.sidebar.pathLastSegmentOnly)
        let showsGitBranchIcon = Self.bool(defaults: defaults, key: "sidebarShowGitBranchIcon", defaultValue: false)
        let showsSSH = Self.bool(defaults: defaults, key: "sidebarShowSSH", defaultValue: SidebarWorkspaceDetailDefaults.showSSH)
        let makesPullRequestsClickable = settings.value(for: catalog.sidebar.makePullRequestsClickable)
        let openPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(
            defaults: defaults
        )
        let openPortLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowser(
            defaults: defaults
        )

        let hidesAllDetails = settings.value(for: catalog.sidebar.hideAllDetails)
        let wrapsWorkspaceTitles = SidebarWorkspaceTitleWrapSettings.wraps(defaults: defaults)
        let detailVisibility = SidebarWorkspaceDetailVisibility(
            showWorkspaceDescription: settings.value(for: catalog.sidebar.showWorkspaceDescription),
            showNotificationMessage: settings.value(for: catalog.sidebar.showNotificationMessage),
            hideAllDetails: hidesAllDetails
        )
        let showsWorkspaceDescription = detailVisibility.showsWorkspaceDescription
        let showsNotificationMessage = detailVisibility.showsNotificationMessage

        let showsMetadata = Self.bool(defaults: defaults, key: "sidebarShowStatusPills", defaultValue: SidebarWorkspaceDetailDefaults.showCustomMetadata)
        let showsLog = Self.bool(defaults: defaults, key: "sidebarShowLog", defaultValue: SidebarWorkspaceDetailDefaults.showLog)
        let showsProgress = Self.bool(defaults: defaults, key: "sidebarShowProgress", defaultValue: SidebarWorkspaceDetailDefaults.showProgress)
        let showsBranchDirectory = Self.bool(defaults: defaults, key: "sidebarShowBranchDirectory", defaultValue: SidebarWorkspaceDetailDefaults.showBranchDirectory)
        let showsPullRequests = Self.bool(defaults: defaults, key: "sidebarShowPullRequest", defaultValue: SidebarWorkspaceDetailDefaults.showPullRequests)
        let showsPorts = Self.bool(defaults: defaults, key: "sidebarShowPorts", defaultValue: SidebarWorkspaceDetailDefaults.showPorts)
        let visibleAuxiliaryDetails = SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: showsMetadata,
            showLog: showsLog,
            showProgress: showsProgress,
            showBranchDirectory: showsBranchDirectory,
            showPullRequests: showsPullRequests,
            showPorts: showsPorts,
            hideAllDetails: hidesAllDetails
        )

        let activeTabIndicatorStyle = settings.value(for: catalog.workspaceColors.indicatorStyle)
        let selectionColorHex = defaults.string(forKey: "sidebarSelectionColorHex")
        let notificationBadgeColorHex = defaults.string(forKey: "sidebarNotificationBadgeColorHex")
        let iMessageModeEnabled = IMessageModeSettings.isEnabled(defaults: defaults)

        self.init(
            hidesAllDetails: hidesAllDetails,
            wrapsWorkspaceTitles: wrapsWorkspaceTitles,
            showsWorkspaceDescription: showsWorkspaceDescription,
            sidebarShortcutHintXOffset: sidebarShortcutHintXOffset,
            sidebarShortcutHintYOffset: sidebarShortcutHintYOffset,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            sidebarFontScale: sidebarFontScale,
            showsGitBranch: showsGitBranch,
            usesVerticalBranchLayout: usesVerticalBranchLayout,
            stacksBranchAndDirectory: stacksBranchAndDirectory,
            usesLastSegmentPath: usesLastSegmentPath,
            showsGitBranchIcon: showsGitBranchIcon,
            showsSSH: showsSSH,
            makesPullRequestsClickable: makesPullRequestsClickable,
            openPullRequestLinksInCmuxBrowser: openPullRequestLinksInCmuxBrowser,
            openPortLinksInCmuxBrowser: openPortLinksInCmuxBrowser,
            showsNotificationMessage: showsNotificationMessage,
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            selectionColorHex: selectionColorHex,
            notificationBadgeColorHex: notificationBadgeColorHex,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails,
            iMessageModeEnabled: iMessageModeEnabled
        )
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

/// Freezes `showsModifierShortcutHints` for the row whose context menu is open,
/// so pressing/releasing the modifier key while the menu is up does not flip
/// the underlying row's shortcut badges (which would be visible around the
/// open context menu). All other rows transition live.
struct VerticalTabsSidebar: View {
    // DEBUG-only sidebar drag-failsafe trace sink injected into the lifted
    // `CmuxSidebar.SidebarDragFailsafeMonitor` so the app keeps emitting the
    // `sidebar.dragFailsafe.schedule`/`.fire` events. `nil` in release, matching
    // the original `#if DEBUG` log blocks inside the monitor.
#if DEBUG
    fileprivate static let sidebarDragFailsafeDebugLog: ((_ message: String) -> Void)? = { message in
        cmuxDebugLog(message)
    }
#else
    fileprivate static let sidebarDragFailsafeDebugLog: ((_ message: String) -> Void)? = nil
#endif
    /// Process-lifetime services (nil-default key, faithful to the legacy
    /// `AppDelegate.shared?` short-circuit). VerticalTabsSidebar is a plain
    /// View (not Equatable-gated); the Equatable typing-hot-path row type is
    /// `TabItemView`, which must never gain this property.
    @Environment(\.appEnvironment) private var appEnvironment
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let windowId: UUID
    let onSendFeedback: () -> Void
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    let observedWindow: NSWindow?
    @Environment(TabManager.self) var tabManager
#if DEBUG
    /// Debug-only per-window sidebar drag-state registry injected from the app
    /// composition root (`AppDelegate`). Used to register/unregister this
    /// sidebar's live `SidebarDragState` for the `debug.sidebar.simulate_drag`
    /// reader without reaching the `AppDelegate.shared` singleton.
    @Environment(\.sidebarDragStateRegistry) private var sidebarDragStateRegistry
#endif
    // Observe the coalesced unread projection instead of the notification store
    // so notification churn (terminal/agent activity) no longer reconstructs
    // every workspace row. The store stays available as an unobserved singleton
    // for context-menu actions and pass-down. See SidebarUnreadModel / #2586.
    @EnvironmentObject var sidebarUnread: SidebarUnreadModel
    var notificationStore: TerminalNotificationStore { .shared }
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var sidebarRenderWorkerClient: RenderWorkerClient?
    @Binding var inlineRenameWorkspaceId: UUID?
    @Binding var inlineRenameRequestToken: Int
    @State var modifierKeyMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @StateObject var dragAutoScrollController = SidebarDragAutoScrollController()
    // Owns the extension-sidebar inspector window (CmuxSidebarUI); the only
    // caller is this sidebar's onOpenWindow, so the instance lives here rather
    // than on ContentView.
    @State private var extensionSidebarInspectorWindowController = CmuxExtensionSidebarInspectorWindowController()
    @State private var dragFailsafeMonitor = SidebarDragFailsafeMonitor(
        debugLog: VerticalTabsSidebar.sidebarDragFailsafeDebugLog
    )
    @State private var tabItemSettingsStore = SidebarTabItemSettingsStore(
        initialSidebarFontSize: GhosttyConfig.load().sidebarFontSize
    )
    private let keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State var dragState: SidebarDragState

    /// Seeds the `@State` `SidebarDragState` with the cross-window drag registry
    /// injected from the app composition root. `@State` initializers cannot read
    /// the SwiftUI environment, so the owning view (`ContentView`) reads
    /// `\.sidebarWorkspaceDragRegistry` and threads the registry here, inverting
    /// the former `AppDelegate.shared` lookup the `SidebarDragState()`
    /// convenience initializer performed.
    @MainActor
    init(
        updateViewModel: UpdateStateModel,
        fileExplorerState: FileExplorerState,
        windowId: UUID,
        onSendFeedback: @escaping () -> Void,
        onToggleSidebar: @escaping () -> Void,
        onNewTab: @escaping () -> Void,
        observedWindow: NSWindow?,
        selection: Binding<SidebarSelection>,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>,
        sidebarRenderWorkerClient: Binding<RenderWorkerClient?>,
        inlineRenameWorkspaceId: Binding<UUID?>,
        inlineRenameRequestToken: Binding<Int>,
        workspaceDragRegistry: any SidebarWorkspaceDragRegistering
    ) {
        self.updateViewModel = updateViewModel
        self._fileExplorerState = ObservedObject(wrappedValue: fileExplorerState)
        self.windowId = windowId
        self.onSendFeedback = onSendFeedback
        self.onToggleSidebar = onToggleSidebar
        self.onNewTab = onNewTab
        self.observedWindow = observedWindow
        self._selection = selection
        self._selectedTabIds = selectedTabIds
        self._lastSidebarSelectionIndex = lastSidebarSelectionIndex
        self._sidebarRenderWorkerClient = sidebarRenderWorkerClient
        self._inlineRenameWorkspaceId = inlineRenameWorkspaceId
        self._inlineRenameRequestToken = inlineRenameRequestToken
        self._dragState = State(
            initialValue: SidebarDragState(workspaceDragRegistry: workspaceDragRegistry)
        )
    }
    // Bonsplit tab drags arrive through AppKit pasteboard callbacks, not
    // `SidebarDragState`, so they need a separate transient collection flag.
    @State private var isBonsplitWorkspaceDropTargetCollectionActive = false
    @State private var bonsplitWorkspaceDropTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()
    // Freezes `showsModifierShortcutHints` for the workspace whose context menu
    // is open. Set on the row's contextMenu.onAppear and cleared on
    // .onDisappear so modifier-key transitions don't flip the badges on the
    // row sitting behind the open menu. See `SidebarShortcutHintFreezePolicy`.
    @State private var frozenShortcutHintsTabId: UUID?
    @State private var frozenShortcutHintsValue: Bool = false
    @State private var pendingSelectedWorkspaceScrollId: UUID?
    @State private var collapsedExtensionSidebarSectionIds: Set<String> = []
    @State private var extensionSidebarWorktreeCreationInFlightSectionIds: Set<String> = []
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
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(CmuxExtensionSidebarSelection.defaultsKey)
    private var selectedExtensionSidebarProviderId = CmuxExtensionSidebarSelection.defaultProviderId
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled
    @LiveSetting(\.betaFeatures.customSidebars) private var customSidebarsExperimentalEnabled
    @LiveSetting(\.customSidebars.renderer) private var customSidebarRenderer
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints

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
        if selected.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix) {
            // Touch the @LiveSetting so toggling the flag in Settings still
            // re-renders, but decide with the synchronous UserDefaults read:
            // on a sidebar remount @LiveSetting's initial value lags one tick,
            // which would otherwise flash the default sidebar for a frame
            // before swapping to the custom one.
            _ = customSidebarsExperimentalEnabled
            return CmuxExtensionSidebarSelection().customSidebarsEnabled
                ? selected
                : CmuxExtensionSidebarSelection.defaultProviderId
        }
        return CmuxExtensionSidebarSelection().effectiveProviderId(
            selectedExtensionSidebarProviderId,
            extensionsEnabled: extensionsExperimentalEnabled
        )
    }

    /// Live, read-only projection of workspace state handed to custom
    /// sidebars so interpreted Swift can bind to it (e.g.
    /// `ForEach(workspaces) { w in Text(w.title) }`) and re-render when it
    /// changes. A value snapshot built fresh each render, never the store
    /// itself, so it respects the sidebar snapshot-boundary rule.
    private func customSidebarDataContext(now: Date) -> [String: SwiftValue] {
        let selectedId = tabManager.selectedTabId
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            customSidebarWorkspaceSnapshot(workspace, index: index, selectedId: selectedId)
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: workspaces,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
            totalUnreadCount: sidebarUnread.totalUnreadCount,
            now: now
        )
        return CustomSidebarDataContextBuilder().dataContext(for: snapshot)
    }

    /// Projects one workspace's live state into the interpreter input snapshot.
    /// The SwiftValue assembly and optional-field omission rules live in
    /// `CustomSidebarDataContextBuilder`; keep the projected fields in sync with
    /// the data keys documented in `docs/custom-sidebars.md`.
    private func customSidebarWorkspaceSnapshot(_ workspace: Workspace, index: Int, selectedId: UUID?) -> CustomSidebarWorkspaceSnapshot {
        let focusedPanelId = workspace.focusedPanelId
        let firstBranch = workspace.sidebarGitBranchesInDisplayOrder().first
        let progress = workspace.progress.map {
            CustomSidebarWorkspaceSnapshot.Progress(value: $0.value, label: $0.label)
        }
        let remote = workspace.remoteDisplayTarget.map { target in
            CustomSidebarWorkspaceSnapshot.Remote(
                target: target,
                stateRawValue: workspace.remoteConnectionState.rawValue,
                isConnected: workspace.remoteConnectionState == .connected
            )
        }
        return CustomSidebarWorkspaceSnapshot(
            id: workspace.id,
            title: workspace.customTitle ?? workspace.title,
            isSelected: workspace.id == selectedId,
            isPinned: workspace.isPinned,
            index: index,
            directory: workspace.currentDirectory,
            listeningPorts: workspace.listeningPorts,
            unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id),
            surfaces: customSidebarSurfaceSnapshots(workspace, focusedPanelId: focusedPanelId),
            surfaceCount: workspace.bonsplitController.allPaneIds.reduce(0) { $0 + workspace.bonsplitController.tabs(inPane: $1).count },
            customDescription: workspace.customDescription,
            customColor: workspace.customColor,
            gitBranch: firstBranch?.branch,
            gitIsDirty: firstBranch?.isDirty ?? false,
            pullRequestValues: workspace.customSidebarPullRequestValues(),
            progress: progress,
            latestConversationMessage: workspace.latestConversationMessage,
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            remote: remote
        )
    }

    /// Projects a workspace's surfaces (terminal/browser/etc. tabs) into the
    /// interpreter input snapshots, enriched with per-surface directory, pin,
    /// git, and ports where available.
    private func customSidebarSurfaceSnapshots(_ workspace: Workspace, focusedPanelId: UUID?) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                let git = workspace.panelGitBranches[panelId]
                surfaces.append(
                    CustomSidebarSurfaceSnapshot(
                        panelId: panelId,
                        title: tab.title,
                        isFocused: panelId == focusedPanelId,
                        isPinned: workspace.pinnedPanelIds.contains(panelId),
                        directory: workspace.panelDirectories[panelId],
                        gitBranch: git?.branch,
                        gitIsDirty: git?.isDirty ?? false,
                        listeningPorts: workspace.surfaceListeningPorts[panelId] ?? []
                    )
                )
            }
        }
        return surfaces
    }
    @AppStorage("sidebarMatchTerminalBackground")
    private var sidebarMatchTerminalBackground = false
    @AppStorage(MinimalModeTitlebarDebugSnapshot.leftControlsLeadingInsetKey)
    private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSnapshot.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSnapshot.leftControlsTopInsetKey)
    private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSnapshot.defaultLeftControlsTopInset

    let tabRowSpacing: CGFloat = 2
    private static let extensionSidebarObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)
    private static let extensionSidebarDisclosureAnimation = Animation.easeInOut(duration: 0.18)
    private var sidebarTitlebarInteractionHeight: CGFloat {
        MinimalModeChromeMetrics.titlebarHeight
    }

    /// Adapter binding for unmigrated consumers (extension sidebar drop
    /// delegates, bonsplit overlays) that still expect @Binding<UUID?>. Reads
    /// flow through `dragState.draggedTabId` so @Observable per-property
    /// tracking still applies to whoever calls the binding's get.
    private var draggedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { dragState.draggedTabId },
            // Route the clear through `clearDrag()` so a locally originated drag
            // also ends its `SidebarWorkspaceDragRegistry` entry. The extension /
            // browser-stack sidebar drop delegates end drags by writing `nil`
            // through this binding; without this they'd leave the process-wide
            // registry stale and a later cross-window drop could act on it.
            set: { newValue in
                if let newValue {
                    dragState.draggedTabId = newValue
                } else {
                    dragState.clearDrag()
                }
            }
        )
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
            lastTabId: reorderIds.last
        )
    }

    /// Constructs the drop delegate for the empty area in the parent scope,
    /// so the child view receives a closure-bundle-equivalent value rather
    /// than an `@Observable` store.
    private func emptyAreaTabDropDelegate(renderContext: WorkspaceListRenderContext) -> SidebarTabDropDelegate {
        SidebarTabDropDelegate(
            targetTabId: nil,
            host: SidebarTabReorderHost(tabManager: tabManager),
            workspaceGroupIdByWorkspaceId: renderContext.workspaceGroupIdByWorkspaceId,
            dragState: dragState,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: nil,
            dragAutoScrollController: dragAutoScrollController
        )
    }

    /// The app-target side effects `SidebarEmptyArea`'s double-tap triggers,
    /// bound to this window's `TabManager` plus `AppDelegate.shared`
    /// new-workspace routing so the lifted view holds no app-target references.
    private func sidebarEmptyAreaActions() -> SidebarEmptyAreaActions {
        // Resolve the environment TabManager and selection binding once during
        // body so the closures capture stable references, matching how
        // `emptyAreaTabDropDelegate` resolves `tabManager` into its host.
        let tabManager = tabManager
        let selectionBinding = $selection
        return SidebarEmptyAreaActions(
            selectedTabIsRemoteTmuxMirror: { tabManager.selectedTab?.isRemoteTmuxMirror == true },
            performNewWorkspaceAction: {
                _ = appEnvironment?.mainWindowRouter.performNewWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "sidebar.emptyArea.remoteTmux"
                )
            },
            addWorkspaceAtEnd: { tabManager.addWorkspace(placementOverride: .end) },
            selectedTabId: { tabManager.selectedTabId },
            tabIndex: { id in tabManager.tabs.firstIndex { $0.id == id } },
            selectTabs: { selectionBinding.wrappedValue = .tabs }
        )
    }

    /// The app-target bonsplit tab-to-new-workspace drop overlay, erased so the
    /// lifted `SidebarEmptyArea` can host it without referencing the app target.
    private func sidebarBonsplitDropOverlay() -> AnyView {
        AnyView(
            SidebarBonsplitTabNewWorkspaceDropOverlay(
                tabManager: tabManager,
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                dropIndicator: dropIndicatorBinding
            )
        )
    }

    private var sidebarTopScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.topScrimHeight
    }

    private var sidebarBottomScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.bottomScrimHeight
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSnapshot.clamped(
                titlebarLeftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSnapshot.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSnapshot.clamped(
                titlebarLeftControlsTopInset,
                range: MinimalModeTitlebarDebugSnapshot.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSnapshot.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSnapshot.defaultTrafficLightTitlebarLeadingInset
        )
    }

    private var minimalModeSidebarTitlebarControlsTopPadding: CGFloat {
        guard let observedWindow else {
            return MinimalModeSidebarTitlebarControlsMetrics().topInset
        }
        return observedWindow.minimalModeSidebarTitlebarControlsTopInset()
    }

    private var showsSidebarNotificationMessage: Bool {
        tabItemSettingsStore.snapshot.showsNotificationMessage
    }

    private var workspaceNumberShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
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
        let movedWorkspaceIds = WorkspaceOrderDidChangeEvent(notification)?.movedWorkspaceIds ?? []
        guard movedWorkspaceIds.contains(selectedWorkspaceId) else { return }
        pendingSelectedWorkspaceScrollId = selectedWorkspaceId
    }

    struct WorkspaceListRenderContext {
        let tabs: [Workspace]
        /// Stored snapshot of `tabs.map(\.id)` so per-row predicates that need
        /// it (e.g. `SidebarTabDropIndicatorPredicate.topVisible`) don't pay
        /// O(n) per row.
        let tabIds: [UUID]
        /// Drag-scope row ids shared by every visible row for this render pass.
        let sidebarReorderIds: [UUID]
        let workspaceCount: Int
        let canCloseWorkspace: Bool
        let workspaceNumberShortcut: StoredShortcut
        let tabItemSettings: SidebarTabItemSettingsSnapshot
        let tabIndexById: [UUID: Int]
        let workspaceById: [UUID: Workspace]
        let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
        let selectedContextTargetIds: [UUID]
        let selectedRemoteContextMenuWorkspaceIds: [UUID]
        let allSelectedRemoteContextMenuTargetsConnecting: Bool
        let allSelectedRemoteContextMenuTargetsDisconnected: Bool
        let workspaceGroups: [WorkspaceGroup]
        let workspaceGroupById: [UUID: WorkspaceGroup]
        let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
        let workspaceRenderItems: [SidebarWorkspaceRenderItem]
        let visibleWorkspaceRowIds: [UUID]

        var workspaceIds: [UUID] { tabIds }
    }

    var body: some View {
        let tabs = tabManager.tabs
        let workspaceCount = tabs.count
        let canCloseWorkspace = workspaceCount > 1
        let workspaceNumberShortcut = self.workspaceNumberShortcut
        let tabItemSettings = tabItemSettingsStore.snapshot
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let workspaceById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let workspaceGroupIdByWorkspaceId = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.groupId) })
        let orderedSelectedTabs = tabs.filter { selectedTabIds.contains($0.id) }
        let selectedContextTargetIds = orderedSelectedTabs.map(\.id)
        let selectedRemoteContextMenuTargets = orderedSelectedTabs.filter { $0.isRemoteWorkspace }
        let selectedRemoteContextMenuWorkspaceIds = selectedRemoteContextMenuTargets.map(\.id)
        let allSelectedRemoteContextMenuTargetsConnecting = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy {
                $0.remoteConnectionState == .connecting || $0.remoteConnectionState == .reconnecting
            }
        let allSelectedRemoteContextMenuTargetsDisconnected = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .disconnected }
        let workspaceGroups = tabManager.workspaceGroups
        let workspaceGroupById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let workspaceGroupMenuSnapshot = WorkspaceGroupMenuSnapshot(
            items: workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        )
        let workspaceRenderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: workspaceGroupById
        )
        let visibleWorkspaceRowIds = workspaceRenderItems.map(\.rowWorkspaceId)
        let draggedSidebarTabId = dragState.draggedTabId
        let sidebarReorderIds = draggedSidebarTabId.map {
            tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: $0,
                usesTopLevelRows: dragState.dropIndicatorUsesTopLevelRows
            )
        } ?? []
        let renderContext = WorkspaceListRenderContext(
            tabs: tabs,
            tabIds: tabs.map(\.id),
            sidebarReorderIds: sidebarReorderIds,
            workspaceCount: workspaceCount,
            canCloseWorkspace: canCloseWorkspace,
            workspaceNumberShortcut: workspaceNumberShortcut,
            tabItemSettings: tabItemSettings,
            tabIndexById: tabIndexById,
            workspaceById: workspaceById,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId,
            selectedContextTargetIds: selectedContextTargetIds,
            selectedRemoteContextMenuWorkspaceIds: selectedRemoteContextMenuWorkspaceIds,
            allSelectedRemoteContextMenuTargetsConnecting: allSelectedRemoteContextMenuTargetsConnecting,
            allSelectedRemoteContextMenuTargetsDisconnected: allSelectedRemoteContextMenuTargetsDisconnected,
            workspaceGroups: workspaceGroups,
            workspaceGroupById: workspaceGroupById,
            workspaceGroupMenuSnapshot: workspaceGroupMenuSnapshot,
            workspaceRenderItems: workspaceRenderItems,
            visibleWorkspaceRowIds: visibleWorkspaceRowIds
        )

        ZStack(alignment: .bottomLeading) {
            if CmuxExtensionSidebarSelection().resolvesToDefaultSidebar(effectiveProviderId: effectiveExtensionSidebarProviderId) {
                workspaceScrollArea(renderContext: renderContext)
            } else {
                extensionSidebarScrollArea(renderContext: renderContext)
            }
            SidebarFooterHostView(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("Sidebar")
        .ignoresSafeArea()
        .overlay(alignment: .trailing) {
            WindowChromeBorder(
                orientation: .vertical,
                refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
                backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
            )
        }
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                modifierKeyMonitor.setHostWindow(showModifierHoldHints ? window : nil)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            if showModifierHoldHints {
                modifierKeyMonitor.setHostWindow(observedWindow)
                modifierKeyMonitor.start()
            } else {
                modifierKeyMonitor.stop()
            }
            dragState.clearDrag()
            isBonsplitWorkspaceDropTargetCollectionActive = false
            // Defensive reset: if a prior simulation died without running
            // its teardown (sidebar unmounted mid-loop, app crash, etc.) the
            // @State SidebarDragState could carry isSimulated=true into a
            // re-mount, which would silently bypass the real-drag failsafe.
            dragState.isSimulated = false
            #if DEBUG
            sidebarDragStateRegistry?.register(windowId: windowId, dragState: dragState)
            #endif
            SidebarDragLifecycleNotification().postStateDidChange(
                tabId: nil,
                reason: "sidebar_appear"
            )
        }
        .onDisappear {
            modifierKeyMonitor.stop()
            dragAutoScrollController.stop()
            dragFailsafeMonitor.stop()
            dragState.clearDrag()
            isBonsplitWorkspaceDropTargetCollectionActive = false
            // Clear the simulator flag too so a re-mounted sidebar doesn't
            // inherit a stale bypass and skip the real-drag failsafe monitor.
            dragState.isSimulated = false
            #if DEBUG
            sidebarDragStateRegistry?.unregister(windowId: windowId)
            #endif
            SidebarDragLifecycleNotification().postStateDidChange(
                tabId: nil,
                reason: "sidebar_disappear"
            )
        }
        .onChange(of: showModifierHoldHints) { _, enabled in
            if enabled {
                modifierKeyMonitor.setHostWindow(observedWindow)
                modifierKeyMonitor.start()
            } else {
                modifierKeyMonitor.stop()
                frozenShortcutHintsTabId = nil
                frozenShortcutHintsValue = false
            }
        }
        .onChange(of: dragState.draggedTabId) { newDraggedTabId in
            SidebarDragLifecycleNotification().postStateDidChange(
                tabId: newDraggedTabId,
                reason: "drag_state_change"
            )
#if DEBUG
            cmuxDebugLog("sidebar.dragState.sidebar tab=\(debugShortSidebarTabId(newDraggedTabId))")
#endif
            if newDraggedTabId != nil {
                // The failsafe monitor probes the real mouse-button state and
                // posts `mouse_up_failsafe` if no mouse is held down. That's
                // correct for HID-driven drags, but `debug.sidebar.simulate_drag`
                // drives the state without any mouse, so skip the monitor when
                // a simulated drag is in flight.
                if !dragState.isSimulated {
                    dragFailsafeMonitor.start {
                        SidebarDragLifecycleNotification().postClearRequest(reason: $0)
                    }
                }
                return
            }
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dragState.clearDropIndicator()
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.requestClear)) { notification in
            guard dragState.draggedTabId != nil || dragState.dropIndicator != nil else { return }
            let reason = SidebarDragLifecycleNotification().reason(from: notification)
#if DEBUG
            cmuxDebugLog("sidebar.dragClear tab=\(debugShortSidebarTabId(dragState.draggedTabId)) reason=\(reason)")
#endif
            dragState.clearDrag()
        }
        .onChange(of: tabManager.tabs.map(\.id)) { tabIds in
            guard let frozenTabId = frozenShortcutHintsTabId,
                  !tabIds.contains(frozenTabId) else { return }
            frozenShortcutHintsTabId = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workspaceScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        let scrollInsets = SidebarWorkspaceScrollInsets.workspaceList
        return ScrollViewReader { scrollProxy in
            SidebarScrollColumn(
                topInset: scrollInsets.top,
                bottomInset: scrollInsets.bottom,
                topScrimHeight: sidebarTopScrimHeight,
                bottomScrimHeight: sidebarBottomScrimHeight,
                isMinimalMode: isMinimalMode,
                minimalControlsLeadingInset: CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset),
                minimalControlsTopPadding: minimalModeSidebarTitlebarControlsTopPadding,
                configureScrollView: { scrollView in
                    configureSidebarScrollView(scrollView)
                    dragAutoScrollController.attach(scrollView: scrollView)
                },
                content: { geometryProxy in
                    workspaceScrollContent(
                        renderContext: renderContext,
                        minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                            viewportHeight: geometryProxy.size.height,
                            insets: scrollInsets
                        )
                    )
                },
                titlebarOverlay: {
                    // The sidebar top strip remains draggable and handles
                    // double-clicks with the standard titlebar action.
                    WindowDragHandleView()
                        .frame(height: sidebarTitlebarInteractionHeight)
                        .background(TitlebarDoubleClickMonitorView())
                },
                minimalControls: {
                    HiddenTitlebarSidebarControlsView(
                        notificationStore: notificationStore,
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
            )
                .overlay(alignment: .top) {
                    if dragState.draggedTabId != nil, let firstWorkspaceId = renderContext.workspaceIds.first {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(height: scrollInsets.top + 8)
                            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: SidebarTabDropDelegate(
                                targetTabId: firstWorkspaceId,
                                host: SidebarTabReorderHost(tabManager: tabManager),
                                workspaceGroupIdByWorkspaceId: renderContext.workspaceGroupIdByWorkspaceId,
                                dragState: dragState,
                                selectedTabIds: $selectedTabIds,
                                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                                targetRowHeight: nil,
                                dragAutoScrollController: dragAutoScrollController
                            ))
                    }
                }
                .onAppear {
                    requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                }
                .onChange(of: tabManager.selectedTabId) { _, _ in
                    requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
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
                .onReceive(NotificationCenter.default.publisher(for: WorkspaceOrderDidChangeEvent.notificationName)) { notification in
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
            .onAppear {
                refreshExtensionSidebarObservationPublishers(tabs: renderContext.tabs)
            }
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
                actionHandler: { handleCMUXSidebarExtensionAction($0) },
                onUseDefaultSidebar: {
                    CmuxExtensionSidebarSelection().setProviderId(CmuxSidebarProviderDescriptor.defaultWorkspacesID)
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
                  let customSidebarURL = CmuxExtensionSidebarSelection().customSidebarFileURL(forProviderId: effectiveExtensionSidebarProviderId) {
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
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                CustomSidebarSurface(
                    fileURL: customSidebarURL,
                    dataContext: customSidebarDataContext(now: timeline.date),
                    dispatch: makeCmuxSidebarActionDispatch(),
                    contentInsets: CustomSidebarContentInsets(
                        top: SidebarWorkspaceScrollInsets.workspaceList.top,
                        bottom: SidebarWorkspaceScrollInsets.workspaceList.bottom
                    ),
                    rendersInProcess: customSidebarRenderer == .inProcess,
                    client: $sidebarRenderWorkerClient
                )
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let model = extensionSidebarRenderModel(renderContext: renderContext, now: timeline.date)
                extensionSidebarTimelineContent(renderContext: renderContext, model: model, now: timeline.date)
            }
        }
    }

    private func extensionSidebarTimelineContent(
        renderContext: WorkspaceListRenderContext,
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        SidebarScrollColumn(
            topInset: SidebarWorkspaceScrollInsets.workspaceList.top,
            bottomInset: SidebarWorkspaceScrollInsets.workspaceList.bottom,
            topScrimHeight: sidebarTopScrimHeight,
            bottomScrimHeight: sidebarBottomScrimHeight,
            isMinimalMode: isMinimalMode,
            minimalControlsLeadingInset: CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset),
            minimalControlsTopPadding: minimalModeSidebarTitlebarControlsTopPadding,
            configureScrollView: { scrollView in
                configureSidebarScrollView(scrollView)
                dragAutoScrollController.attach(scrollView: scrollView)
            },
            content: { geometryProxy in
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
                    ExtensionSidebarSectionsColumn(
                        sections: model.sections,
                        rowVerticalPadding: SidebarWorkspaceListMetrics.rowVerticalPadding,
                        bottomPadding: SidebarWorkspaceListMetrics.rowVerticalPadding + 40,
                        contentMinHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                            viewportHeight: geometryProxy.size.height,
                            insets: SidebarWorkspaceScrollInsets.workspaceList
                        ),
                        makeSection: { section in
                            extensionSidebarSection(section, providerId: model.providerId, now: now)
                        },
                        emptyArea: {
                            SidebarEmptyArea(
                                rowSpacing: tabRowSpacing,
                                selectedTabIds: $selectedTabIds,
                                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                                dragAutoScrollController: dragAutoScrollController,
                                actions: sidebarEmptyAreaActions(),
                                topDropIndicatorVisible: emptyAreaTopDropIndicatorVisible(),
                                tabDropDelegate: emptyAreaTabDropDelegate(renderContext: renderContext),
                                bonsplitDropIndicator: dropIndicatorBinding,
                                topDropIndicatorColor: { cmuxAccentColor() },
                                bonsplitDropOverlay: sidebarBonsplitDropOverlay
                            )
                            .frame(maxWidth: .infinity, minHeight: 48)
                        }
                    )
                }
            },
            titlebarOverlay: {
                WindowDragHandleView()
                    .frame(height: sidebarTitlebarInteractionHeight)
                    .background(TitlebarDoubleClickMonitorView())
            },
            minimalControls: {
                HiddenTitlebarSidebarControlsView(
                    notificationStore: notificationStore,
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
        )
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

    private func refreshExtensionSidebarSnapshot() {
        extensionSidebarUpdateToken &+= 1
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

        extensionSidebarImmediateObservationPublisher = Publishers.MergeMany(
            tabs.map { $0.sidebarImmediateObservationPublisher }
        )
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
        extensionSidebarDebouncedObservationPublisher = Publishers.MergeMany(
            tabs.map { $0.sidebarObservationPublisher }
        )
        .receive(on: RunLoop.main)
        .debounce(for: Self.extensionSidebarObservationCoalesceInterval, scheduler: RunLoop.main)
        .eraseToAnyPublisher()
    }

    private func extensionSidebarRenderModel(
        renderContext: WorkspaceListRenderContext,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        let _ = extensionSidebarUpdateToken
        let snapshot = extensionSidebarSnapshot(renderContext: renderContext)
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
        if let provider = CmuxExtensionSidebarSelection().provider(for: providerId) {
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
        renderContext: WorkspaceListRenderContext
    ) -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(workspaces: renderContext.tabs)
    }

    private func extensionSidebarSnapshotForCurrentTabs() -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(workspaces: tabManager.tabs)
    }

    private func cmuxSidebarSnapshotForCurrentTabs() -> CmuxSidebarSnapshot {
        ExtensionSidebarSnapshotBuilder().cmuxSidebarSnapshot(
            from: extensionSidebarSnapshotForCurrentTabs(),
            surfaces: { cmuxSidebarSurfaces(for: $0) }
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
                workingDirectory: liveWorkspace.panelDirectories[panelId]
            )
        }
    }

    private func cmuxSidebarSurfaceKind(for panelType: PanelType) -> CmuxSidebarSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .unknown
        case .customSidebar:
            return .unknown
        }
    }

    private func handleCMUXSidebarExtensionAction(
        _ action: CmuxSidebarAction
    ) -> CmuxSidebarActionResult {
        switch action {
        case .createWorkspace(let title, let workingDirectory, let select):
            let workspace = tabManager.addWorkspace(
                title: title,
                workingDirectory: workingDirectory,
                inheritWorkingDirectory: workingDirectory == nil,
                select: select
            )
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
            let validatedURL = SidebarExtensionOptionalHTTPURL(validating: urlString)
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
            guard let splitDirection = splitDirection(from: direction),
                  let panelId = tabManager.createSplit(tabId: workspaceId, surfaceId: surfaceId, direction: splitDirection) else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            return CmuxSidebarActionResult(accepted: true, message: panelId.uuidString)

        case .splitBrowser(let workspaceId, let surfaceId, let direction, let urlString):
            let validatedURL = SidebarExtensionOptionalHTTPURL(validating: urlString)
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
            guard let url = URL.sidebarExtensionHTTPURL(from: urlString),
                  NSWorkspace.shared.open(url) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened")
                )
            }
            return .accepted
        }
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

    private func extensionSidebarSnapshot(workspaces: [Workspace]) -> CmuxSidebarProviderSnapshot {
        CmuxSidebarProviderSnapshot(
            sequence: UInt64(max(0, CmuxEventBus.shared.latestSequence)),
            selectedWorkspaceId: tabManager.selectedTabId,
            workspaces: workspaces.map(extensionWorkspaceSnapshot(for:)),
            windowId: windowId
        )
    }

    private func extensionWorkspaceSnapshot(for workspace: Workspace) -> CmuxSidebarProviderWorkspace {
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
            unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id),
            latestNotificationText: sidebarUnread.latestNotificationText(forWorkspaceId: workspace.id),
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            listeningPorts: workspace.listeningPorts,
            pullRequestURLs: workspace.sidebarPullRequestsInDisplayOrder().map { $0.url.absoluteString },
            panelDirectories: workspace.sidebarDirectoriesInDisplayOrder(),
            gitBranches: workspace.sidebarGitBranchesInDisplayOrder().map {
                CmuxSidebarProviderGitBranch(branch: $0.branch, isDirty: $0.isDirty)
            }
        )
    }

    private func extensionSidebarRootPath(for workspace: Workspace) -> String? {
        workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Host-side action bundle handed to the extracted browser-stack column
    /// views (`CmuxSidebarUI.ExtensionBrowserStackColumnView` and its children).
    /// Inverts every reach back into app-target state (selection, reorder
    /// mutations, new-tab, provider-text resolution) so the package views hold
    /// only value snapshots.
    private var extensionBrowserStackActions: ExtensionBrowserStackActions {
        ExtensionBrowserStackActions(
            selectWorkspace: { selectExtensionSidebarWorkspace($0) },
            commitMutation: { handleExtensionSidebarMutation($0) },
            moveWorkspace: { workspaceId, delta in
                moveExtensionBrowserStackWorkspace(workspaceId, by: delta)
            },
            newTab: onNewTab,
            renderText: { text, now in extensionSidebarRenderedText(text, now: now) }
        )
    }

    private func extensionBrowserStackSidebar(
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        ExtensionBrowserStackColumnView(
            model: model,
            now: now,
            selectedWorkspaceId: tabManager.selectedTabId,
            tabRowSpacing: tabRowSpacing,
            bottomPadding: SidebarWorkspaceListMetrics.rowVerticalPadding + 40,
            accent: cmuxAccentColor(),
            dragState: dragState,
            dragAutoScrollController: dragAutoScrollController,
            actions: extensionBrowserStackActions
        )
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
        let descriptor = CmuxExtensionSidebarSelection().descriptor(for: effectiveExtensionSidebarProviderId)
        guard let provider = CmuxExtensionSidebarSelection().provider(for: descriptor.id) as? any CmuxMutableSidebarProvider else {
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
        ExtensionSidebarSnapshotBuilder().workspaceSnapshotsById(
            for: rows,
            snapshot: { extensionWorkspaceSnapshot(for: $0) }
        )
    }

    private func extensionSidebarRenderedText(_ text: CmuxSidebarProviderText?, now: Date) -> String? {
        ExtensionSidebarSnapshotBuilder().renderedText(
            text,
            now: now,
            relativeDate: { CmuxExtensionRelativeTimeFormatter().string(from: $0, to: $1) }
        )
    }

    @ViewBuilder
    private func extensionSidebarSection(
        _ section: CmuxSidebarProviderSection,
        providerId: String,
        now: Date
    ) -> ExtensionSidebarSectionView {
        let isCollapsed = collapsedExtensionSidebarSectionIds.contains(section.id)
        ExtensionSidebarSectionView(
            section: section,
            providerId: providerId,
            now: now,
            isCollapsed: isCollapsed,
            isWorktreeCreationInFlight: extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id),
            canCreateWorktree: section.treeSection.projectRootPath != nil,
            selectedWorkspaceId: tabManager.selectedTabId,
            workspaceSnapshotsById: extensionSidebarWorkspaceSnapshotsById(for: section.rows),
            treeSectionTitle: extensionSidebarTreeSectionTitle(section.treeSection),
            toggleHelp: String(localized: "sidebar.extension.toggleSection", defaultValue: "Toggle section"),
            createWorktreeHelp: String(localized: "sidebar.extension.createWorktree", defaultValue: "Create worktree"),
            disclosureAnimation: Self.extensionSidebarDisclosureAnimation,
            onToggle: {
                if isCollapsed {
                    collapsedExtensionSidebarSectionIds.remove(section.id)
                } else {
                    collapsedExtensionSidebarSectionIds.insert(section.id)
                }
            },
            onCreateWorktree: {
                createExtensionWorktreeWorkspace(for: section.treeSection)
            },
            onSelect: selectExtensionSidebarWorkspace,
            onOpenWindow: extensionSidebarInspectorWindowController.show
        )
    }

    private func extensionWorkspaceSnapshot(for workspaceId: UUID) -> CmuxSidebarProviderWorkspace? {
        tabManager.tabs.first { $0.id == workspaceId }.map(extensionWorkspaceSnapshot(for:))
    }

    private func extensionSidebarTreeSectionTitle(_ section: CmuxSidebarProviderTreeSection) -> String {
        ExtensionSidebarSnapshotBuilder().treeSectionTitle(section)
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
                tabManager.addWorkspace(
                    title: spawnArgs.title,
                    workingDirectory: spawnArgs.workingDirectory,
                    initialTerminalInput: spawnArgs.initialTerminalInput,
                    inheritWorkingDirectory: spawnArgs.inheritWorkingDirectory,
                    select: true,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: spawnArgs.initialTerminalInput == nil
                )
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
        minHeight: CGFloat
    ) -> some View {
        // Rows stay lazy + pinned top; `.frame(minHeight:)` fills the viewport
        // (#3241) or scrolls without measuring the LazyVStack. The prior
        // SidebarRowsFillLayout measured it (`sizeThatFits(height: nil)`) every
        // pass, realizing all rows and re-livelocking at scale (#2586 / #5764 /
        // #5845; regressed by #6033). Drop/tap = background; indicator on rows.
        workspaceRows(renderContext: renderContext)
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
            // livelock this change removes. Per-row delegates render in front
            // and still win over their own rows.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {}
                    .onDrop(of: SidebarTabDragPayload.dropContentTypes, isTargeted: nil) { _ in false }
                    .onDrop(of: BonsplitTabTransferPasteboard.dropContentTypes, isTargeted: nil) { _ in false }
            }
            .frame(minHeight: minHeight, alignment: .top)
            .background(alignment: .top) {
                SidebarEmptyArea(
                    rowSpacing: tabRowSpacing,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dragAutoScrollController: dragAutoScrollController,
                    actions: sidebarEmptyAreaActions(),
                    topDropIndicatorVisible: false,
                    tabDropDelegate: emptyAreaTabDropDelegate(renderContext: renderContext),
                    bonsplitDropIndicator: dropIndicatorBinding,
                    topDropIndicatorColor: { cmuxAccentColor() },
                    bonsplitDropOverlay: sidebarBonsplitDropOverlay,
                    expandsVertically: true
                )
            }
    }

    @ViewBuilder
    private func workspaceRows(renderContext: WorkspaceListRenderContext) -> some View {
        let renderItems = renderContext.workspaceRenderItems
        let shouldCollectWorkspaceDropTargets = SidebarDropPlanner().shouldCollectWorkspaceDropTargets(
            draggedTabId: dragState.draggedTabId,
            isBonsplitWorkspaceDropActive: isBonsplitWorkspaceDropTargetCollectionActive
        )
        // LazyVStack is safe here because `dragState` is @Observable:
        // drag mutations at 60fps invalidate only the rows/overlays that
        // read them, never this sidebar body. See SidebarDragState and
        // https://github.com/manaflow-ai/cmux/issues/2586.
        let rows = LazyVStack(spacing: tabRowSpacing) {
            ForEach(renderItems, id: \.id) { item in
                switch item {
                case .groupHeader(let group, let memberWorkspaceIds):
                    sidebarWorkspaceGroupHeader(
                        group: group,
                        memberWorkspaceIds: memberWorkspaceIds,
                        renderContext: renderContext,
                        shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets, showModifierHoldHints: showModifierHoldHints
                    )
                case .workspace(let tab):
                    workspaceRow(
                        tab,
                        renderContext: renderContext,
                        shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
                    )
                }
            }
        }
        .padding(.vertical, SidebarWorkspaceListMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No whole-content height measurement here: reading the LazyVStack's
        // total height (GeometryReader, or a custom Layout's sizeThatFits) fed a
        // non-converging relayout loop (#2586 / #5764 / #5845). Fill is handled
        // by `.frame(minHeight:)` in workspaceScrollContent.

        // Gate ONLY the per-row frame-anchor *reader* (the virtualization-defeating
        // work) behind the drag-active check, and keep the Bonsplit drop-capture
        // overlay mounted *outside* that conditional. Returning the overlay from both
        // branches of an `if`/`else` gives it distinct SwiftUI identity, so flipping the
        // gate mid-drag (draggingEntered -> shouldCollect=true) tore down and recreated
        // the drop NSView, orphaning the in-flight drag. Applying it at the stable outer
        // level keeps the NSView identity-stable across gate flips. (#5325 review)
        rowsWithGatedDropTargetReader(
            rows: rows,
            renderContext: renderContext,
            shouldCollect: shouldCollectWorkspaceDropTargets
        )
        .overlay {
            bonsplitWorkspaceDropOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                        SidebarBonsplitTabWorkspaceDropOverlay.TargetWriter(
                            targetBridge: bonsplitWorkspaceDropTargetBridge,
                            targets: renderContext.tabs.compactMap { tab in
                                guard let anchor = anchors[tab.id] else { return nil }
                                return SidebarDropPlanner.WorkspaceDropTarget(
                                    workspaceId: tab.id,
                                    isPinned: tab.isPinned,
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
                if let source = app.environment.windowRegistry.locateBonsplitSurface(tabId: transfer.tab.id),
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
                guard let result = appEnvironment?.mainWindowRouter.moveBonsplitTabToNewWorkspace(
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

    @ViewBuilder
    private func workspaceRow(
        _ tab: Workspace,
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> some View {
        let index = renderContext.tabIndexById[tab.id] ?? 0
        let usesSelectedContextMenuTargets = selectedTabIds.contains(tab.id)
        let contextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedContextTargetIds
            : [tab.id]
        let remoteContextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedRemoteContextMenuWorkspaceIds
            : (tab.isRemoteWorkspace ? [tab.id] : [])
        let allRemoteContextMenuTargetsConnecting = usesSelectedContextMenuTargets
            ? renderContext.allSelectedRemoteContextMenuTargetsConnecting
            : (
                tab.isRemoteWorkspace &&
                    (tab.remoteConnectionState == .connecting || tab.remoteConnectionState == .reconnecting)
            )
        let allRemoteContextMenuTargetsDisconnected = usesSelectedContextMenuTargets
            ? renderContext.allSelectedRemoteContextMenuTargetsDisconnected
            : (tab.isRemoteWorkspace && tab.remoteConnectionState == .disconnected)
        let contextMenuPinTarget = WorkspaceActionDispatcher.Target(
            workspaceIds: contextMenuWorkspaceIds,
            anchorWorkspaceId: tab.id
        )
        let contextMenuPinState = WorkspaceActionDispatcher.pinState(
            in: tabManager,
            target: contextMenuPinTarget
        )
        let liveUnreadCount = sidebarUnread.unreadCount(forWorkspaceId: tab.id)
        let liveHasMemoryWarning = sidebarUnread.hasMemoryWarning(forWorkspaceId: tab.id)
        let liveLatestNotificationText: String? = showsSidebarNotificationMessage
            ? sidebarUnread.latestNotificationText(forWorkspaceId: tab.id)
            : nil
        let liveShowsModifierShortcutHints = showModifierHoldHints && modifierKeyMonitor.isModifierPressed
        let resolvedShowsModifierShortcutHints = SidebarShortcutHintFreezePolicy().resolved(
            live: liveShowsModifierShortcutHints,
            currentTabId: tab.id,
            frozenTabId: frozenShortcutHintsTabId,
            frozenValue: frozenShortcutHintsValue
        )
        let onContextMenuAppear: () -> Void = { [tabId = tab.id, snapshot = resolvedShowsModifierShortcutHints] in
            frozenShortcutHintsTabId = tabId
            frozenShortcutHintsValue = snapshot
        }
        let onContextMenuDisappear: () -> Void = { [tabId = tab.id] in
            if frozenShortcutHintsTabId == tabId {
                frozenShortcutHintsTabId = nil
            }
        }

        // Per-row drag/drop snapshots. Reading `dragState` here in the parent
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
        let onDragStart: () -> NSItemProvider = { [tabId = tab.id] in
            #if DEBUG
            cmuxDebugLog("sidebar.onDrag tab=\(tabId.uuidString.prefix(5))")
            #endif
            dragState.beginDragging(tabId: tabId)
            return SidebarTabDragPayload(tabId: tabId).provider()
        }
        let tabDropDelegateFactory: (CGFloat) -> SidebarTabDropDelegate = { [
            tabId = tab.id,
            selectedTabIds = $selectedTabIds,
            lastSidebarSelectionIndex = $lastSidebarSelectionIndex
        ] rowHeight in
            SidebarTabDropDelegate(
                targetTabId: tabId,
                host: SidebarTabReorderHost(tabManager: tabManager),
                workspaceGroupIdByWorkspaceId: renderContext.workspaceGroupIdByWorkspaceId,
                dragState: dragState,
                selectedTabIds: selectedTabIds,
                lastSidebarSelectionIndex: lastSidebarSelectionIndex,
                targetRowHeight: rowHeight,
                dragAutoScrollController: dragAutoScrollController
            )
        }
        let inlineRenameRequestTokenForRow = inlineRenameWorkspaceId == tab.id
            ? inlineRenameRequestToken
            : nil
        let onInlineRenameRequestHandled: () -> Void = { [tabId = tab.id] in
            if inlineRenameWorkspaceId == tabId {
                inlineRenameWorkspaceId = nil
            }
        }

        let row = TabItemView(
            tabManager: tabManager,
            notificationStore: notificationStore,
            tab: tab,
            index: index,
            isActive: tabManager.selectedTabId == tab.id,
            workspaceShortcutDigit: WorkspaceShortcutMapper(
                workspaceCount: renderContext.workspaceCount
            ).digitForWorkspace(at: index),
            workspaceShortcutModifierSymbol: renderContext.workspaceNumberShortcut.numberedDigitHintPrefix,
            canCloseWorkspace: renderContext.canCloseWorkspace,
            accessibilityWorkspaceCount: renderContext.workspaceCount,
            unreadCount: liveUnreadCount,
            hasMemoryWarning: liveHasMemoryWarning,
            latestNotificationText: liveLatestNotificationText,
            rowSpacing: tabRowSpacing,
            setSelectionToTabs: { selection = .tabs },
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            showsModifierShortcutHints: resolvedShowsModifierShortcutHints,
            dragAutoScrollController: dragAutoScrollController,
            isBeingDragged: isBeingDragged,
            topDropIndicatorVisible: topDropIndicatorVisible,
            onDragStart: onDragStart,
            tabDropDelegateFactory: tabDropDelegateFactory,
            contextMenuWorkspaceIds: contextMenuWorkspaceIds,
            remoteContextMenuWorkspaceIds: remoteContextMenuWorkspaceIds,
            allRemoteContextMenuTargetsConnecting: allRemoteContextMenuTargetsConnecting,
            allRemoteContextMenuTargetsDisconnected: allRemoteContextMenuTargetsDisconnected,
            contextMenuPinState: contextMenuPinState,
            workspaceGroupMenuSnapshot: renderContext.workspaceGroupMenuSnapshot,
            settings: renderContext.tabItemSettings,
            inlineRenameRequestToken: inlineRenameRequestTokenForRow,
            onInlineRenameRequestHandled: onInlineRenameRequestHandled,
            onContextMenuAppear: onContextMenuAppear,
            onContextMenuDisappear: onContextMenuDisappear
        )
        .equatable()
        .id(tab.id)
        .accessibilityIdentifier("sidebarWorkspace.\(tab.id.uuidString)")

        row
            .sidebarWorkspaceFrameAnchor(id: tab.id, isEnabled: shouldCollectWorkspaceDropTargets)
            .padding(.leading, tab.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

/// App-target host for the lifted `CmuxSidebarUI.SidebarFooter`.
///
/// Owns the two reactive reads that drive the footer (the experimental
/// extensions `@LiveSetting` and the keyboard-shortcut revision observer) and
/// resolves every localized string and `AppDelegate`/`BrowserDataImportCoordinator`
/// effect in the app bundle, threading them into the package footer as plain
/// values and `@MainActor` closures. Keeping this thin host between
/// `VerticalTabsSidebar` and the package view preserves the original footer's
/// reactivity scope (only the footer re-renders when the extensions flag or a
/// shortcut binding changes). The former dead-threaded `FileExplorerState`
/// parameter is dropped (it was never read by any footer view).
private struct SidebarFooterHostView: View {
    var updateViewModel: UpdateStateModel
    let onSendFeedback: () -> Void
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled
    private let keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        SidebarFooter(
            updateViewModel: updateViewModel,
            helpTitle: String(localized: "sidebar.help.button", defaultValue: "Help"),
            helpMenuOptions: helpMenuOptions,
            extensionsEnabled: extensionsExperimentalEnabled,
            extensionsBrowserTitle: String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"),
            onOpenExtensionBrowser: { anchorView in
                _ = AppDelegate.shared?.openSidebarExtensionBrowser(
                    from: anchorView,
                    title: String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
                )
            },
            accentColor: cmuxAccentColor(),
            updateActionsHost: AppDelegate.shared,
            devBuildBannerText: String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD")
        )
    }

    private static let docsURL = URL(string: "https://cmux.com/docs")
    private static let changelogURL = URL(string: "https://cmux.com/docs/changelog")
    private static let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private static let githubIssuesURL = URL(string: "https://github.com/manaflow-ai/cmux/issues")
    private static let discordURL = URL(string: "https://discord.gg/xsgFEVrWCZ")

    private var sendFeedbackShortcutHint: String {
        let _ = keyboardShortcutSettingsObserver.revision
        return ShortcutDisplayFormatter().displayString(KeyboardShortcutSettings.shortcut(for: .sendFeedback))
    }

    /// Builds the ordered help-popover rows, resolving every localized title in
    /// the app bundle and mapping each row to its app-target effect. External
    /// links are omitted when their URL fails to construct, matching the legacy
    /// menu's `if url != nil` gating.
    private var helpMenuOptions: [SidebarHelpMenuButton.Option] {
        var options: [SidebarHelpMenuButton.Option] = [
            SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionWelcome",
                title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
                isExternalLink: false
            ) {
                Task { @MainActor in
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.openWelcomeWorkspace()
                    }
                }
            },
            SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionSendFeedback",
                title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
                isExternalLink: false,
                shortcutHint: sendFeedbackShortcutHint,
                trailingSystemImage: "bubble.left.and.text.bubble.right",
                action: onSendFeedback
            ),
            SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionKeyboardShortcuts",
                title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                isExternalLink: false
            ) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    Task { @MainActor in
                        if let appDelegate = AppDelegate.shared {
                            appDelegate.openPreferencesWindow(
                                debugSource: "sidebarHelpMenu.keyboardShortcuts",
                                navigationTarget: .keyboardShortcuts
                            )
                        } else {
                            AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                        }
                    }
                }
            },
            SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionImportBrowserData",
                title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
                isExternalLink: false
            ) {
                DispatchQueue.main.async {
                    BrowserDataImportCoordinator.shared.presentImportDialog()
                }
            },
        ]
        if let docsURL = Self.docsURL {
            options.append(SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionDocs",
                title: String(localized: "about.docs", defaultValue: "Docs"),
                isExternalLink: true
            ) {
                NSWorkspace.shared.open(docsURL)
            })
        }
        if let changelogURL = Self.changelogURL {
            options.append(SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionChangelog",
                title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"),
                isExternalLink: true
            ) {
                NSWorkspace.shared.open(changelogURL)
            })
        }
        if let githubURL = Self.githubURL {
            options.append(SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionGitHub",
                title: String(localized: "about.github", defaultValue: "GitHub"),
                isExternalLink: true
            ) {
                NSWorkspace.shared.open(githubURL)
            })
        }
        if let githubIssuesURL = Self.githubIssuesURL {
            options.append(SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionGitHubIssues",
                title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"),
                isExternalLink: true
            ) {
                NSWorkspace.shared.open(githubIssuesURL)
            })
        }
        if let discordURL = Self.discordURL {
            options.append(SidebarHelpMenuButton.Option(
                id: "SidebarHelpMenuOptionDiscord",
                title: String(localized: "sidebar.help.discord", defaultValue: "Discord"),
                isExternalLink: true
            ) {
                NSWorkspace.shared.open(discordURL)
            })
        }
        options.append(SidebarHelpMenuButton.Option(
            id: "SidebarHelpMenuOptionCheckForUpdates",
            title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
            isExternalLink: false
        ) {
            Task { @MainActor in
                AppDelegate.shared?.checkForUpdates(nil)
            }
        })
        return options
    }
}

// PERF: TabItemView is Equatable so SwiftUI skips body re-evaluation when
// the parent rebuilds with unchanged values. Without this, every TabManager
// or NotificationStore publish causes ALL tab items to re-evaluate (~18% of
// main thread during typing). If you add new properties, update == below.
// Reactive workspace state inside the row must not rely on parent diffs alone:
// `.equatable()` can otherwise leave sidebar badges/details stale until an
// unrelated parent change sneaks through. Keep the workspace reference plain
// and bridge only sidebar-visible workspace changes into local state.
// Do NOT add @EnvironmentObject or new @Binding without updating ==.
// Do NOT remove .equatable() from the ForEach call site in VerticalTabsSidebar.
/// Lifted to `CmuxSidebar.SidebarWorkspaceSnapshotBuilder`; this typealias keeps
/// the unqualified `SidebarWorkspaceSnapshotBuilder` spelling (and its nested
/// `.Snapshot`/`.PresentationKey`/`.VerticalBranchDirectoryLine`/
/// `.PullRequestDisplay` access) resolving for app-target consumers.
typealias SidebarWorkspaceSnapshotBuilder = CmuxSidebar.SidebarWorkspaceSnapshotBuilder

struct TabItemView: View, Equatable {
    private static let workspaceObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)

    // DEBUG-only sidebar-description render log, injected into the lifted
    // `SidebarWorkspaceDescriptionText` package view so the app keeps emitting
    // the `sidebar.description.render` events. `nil` in release, matching the
    // original `#if DEBUG` log block.
#if DEBUG
    private static let sidebarDescriptionDebugLog: ((_ phase: String, _ markdown: String) -> Void)? = { phase, value in
        let workspaceState = phase == "appear" ? "appear" : "change"
        let newlineCount = value.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        cmuxDebugLog(
            "sidebar.description.render workspaceState=\(workspaceState) " +
            "len=\((value as NSString).length) " +
            "newlines=\(newlineCount) " +
            "text=\"\((value).commandPaletteDebugPreview())\""
        )
    }
#else
    private static let sidebarDescriptionDebugLog: ((_ phase: String, _ markdown: String) -> Void)? = nil
#endif

    /// DEBUG trace for a debounced sidebar-row invalidation. Extracted from the
    /// `.onReceive` closure so its string building doesn't push the row's
    /// modifier-chain body over the SwiftUI type-checker's time budget.
    static func logSidebarRowInvalidate(tab: Tab, source: String) {
#if DEBUG
        let description = tab.customDescription ?? ""
        cmuxDebugLog(
            "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
            "source=\(source) " +
            "title=\"\((tab.title).commandPaletteDebugPreview())\" " +
            "descLen=\((description as NSString).length) " +
            "desc=\"\((description).commandPaletteDebugPreview())\""
        )
#endif
    }

    // Closures, Bindings, and object references are excluded from ==
    // because they're recreated every parent eval but don't affect rendering.
    nonisolated static func == (lhs: TabItemView, rhs: TabItemView) -> Bool {
        lhs.tab === rhs.tab &&
        lhs.index == rhs.index &&
        lhs.isActive == rhs.isActive &&
        lhs.workspaceShortcutDigit == rhs.workspaceShortcutDigit &&
        lhs.workspaceShortcutModifierSymbol == rhs.workspaceShortcutModifierSymbol &&
        lhs.canCloseWorkspace == rhs.canCloseWorkspace &&
        lhs.accessibilityWorkspaceCount == rhs.accessibilityWorkspaceCount &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.hasMemoryWarning == rhs.hasMemoryWarning &&
        lhs.latestNotificationText == rhs.latestNotificationText &&
        lhs.rowSpacing == rhs.rowSpacing &&
        lhs.showsModifierShortcutHints == rhs.showsModifierShortcutHints &&
        lhs.contextMenuWorkspaceIds == rhs.contextMenuWorkspaceIds &&
        lhs.remoteContextMenuWorkspaceIds == rhs.remoteContextMenuWorkspaceIds &&
        lhs.allRemoteContextMenuTargetsConnecting == rhs.allRemoteContextMenuTargetsConnecting &&
        lhs.allRemoteContextMenuTargetsDisconnected == rhs.allRemoteContextMenuTargetsDisconnected &&
        lhs.contextMenuPinState == rhs.contextMenuPinState &&
        lhs.workspaceGroupMenuSnapshot == rhs.workspaceGroupMenuSnapshot &&
        lhs.isBeingDragged == rhs.isBeingDragged &&
        lhs.topDropIndicatorVisible == rhs.topDropIndicatorVisible &&
        lhs.inlineRenameRequestToken == rhs.inlineRenameRequestToken &&
        lhs.settings == rhs.settings
    }

    // Use plain references instead of @EnvironmentObject to avoid subscribing
    // to ALL changes on these objects. Body reads use precomputed parameters;
    // action handlers use the plain references without triggering re-evaluation.
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    // Global font magnification percent, read once per row instead of through a
    // per-label `CmuxFontModifier`. Each `.cmuxFont(...)` is a custom
    // `@Environment`-reading `ViewModifier`; with 100+ workspaces continuously
    // re-rendering rows under agent churn, ~20 of those per row multiplied the
    // SwiftUI `DynamicBody`/environment node count the sidebar must re-evaluate
    // on every render pass (issue #6612, regression from #6554). Reading the
    // percent here and applying a primitive `.font(...)` keeps magnification
    // working while dropping those per-label modifier bodies.
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent
#if DEBUG
    // Plain-value environment probe (closure struct, not an object reference):
    // set only by SidebarLazyLayoutScaleTests, default no-op, excluded from ==
    // like all closures. See SidebarLazyContractProbe.
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif
    let tab: Tab
    let index: Int
    let isActive: Bool
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    /// True when any pane in this workspace is over the runaway-memory
    /// threshold. Precomputed snapshot value (snapshot-boundary rule); drives
    /// the orange warning badge alongside the unread badge.
    let hasMemoryWarning: Bool
    let latestNotificationText: String?
    let rowSpacing: CGFloat
    let setSelectionToTabs: () -> Void
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let showsModifierShortcutHints: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    // Row receives precomputed drag/drop snapshot values + action closures
    // instead of an `@Observable` store reference. This keeps TabItemView in
    // compliance with the snapshot-boundary rule for views under a LazyVStack
    // (see CLAUDE.md). When drag state changes, the parent recomputes these
    // per-row snapshots and `==` skips re-render for rows whose snapshot is
    // unchanged.
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let onDragStart: () -> NSItemProvider
    /// Factory invoked from `body` with the row's measured `rowHeight`. Closure
    /// captures the parent's `dragState`, so TabItemView itself never holds an
    /// `@Observable` store reference (snapshot-boundary rule).
    let tabDropDelegateFactory: (CGFloat) -> SidebarTabDropDelegate
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let settings: SidebarTabItemSettingsSnapshot
    let inlineRenameRequestToken: Int?
    let onInlineRenameRequestHandled: () -> Void
    /// Called from this row's contextMenu.onAppear so the parent can freeze
    /// `showsModifierShortcutHints` to the value it last passed in. Prevents
    /// modifier-key transitions from flipping the badges on the row sitting
    /// behind the open context menu.
    let onContextMenuAppear: () -> Void
    let onContextMenuDisappear: () -> Void
    @State private var workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
    @State private var contextMenuState = SidebarTabItemContextMenuModel()
    @State private var rowInteractionState = SidebarWorkspaceRowInteractionState()
    @State private var rowHeight: CGFloat = 1
    @State private var workspaceFinderDirectoryOpenRequest: WorkspaceFinderDirectoryOpenRequest?
    @State private var isEditing = false
    @State private var renameDraft = ""
    @State private var renameBaselineHadUserCustomTitle = false
    @State private var handledInlineRenameRequestToken: Int?

    private static let maxWrappedTitleLines = 8
    private static let maxDisplayedTitleCharacters = 2048

    var isMultiSelected: Bool {
        selectedTabIds.contains(tab.id)
    }

    private var sidebarShortcutHintXOffset: Double {
        settings.sidebarShortcutHintXOffset
    }

    private var sidebarShortcutHintYOffset: Double {
        settings.sidebarShortcutHintYOffset
    }

    private var alwaysShowShortcutHints: Bool {
        settings.alwaysShowShortcutHints
    }

    private var sidebarShowGitBranch: Bool {
        settings.showsGitBranch
    }

    private var sidebarBranchVerticalLayout: Bool {
        settings.usesVerticalBranchLayout
    }

    private var sidebarStacksBranchAndDirectory: Bool {
        settings.stacksBranchAndDirectory
    }

    private var sidebarUsesLastSegmentPath: Bool {
        settings.usesLastSegmentPath
    }

    private var sidebarShowGitBranchIcon: Bool {
        settings.showsGitBranchIcon
    }

    private var sidebarShowSSH: Bool {
        settings.showsSSH
    }

    private var workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot {
        if let workspaceSnapshotStorage,
           workspaceSnapshotStorage.presentationKey == workspaceSnapshotPresentationKey {
            return workspaceSnapshotStorage
        }
        return makeWorkspaceSnapshot()
    }

    private var activeTabIndicatorStyle: WorkspaceIndicatorStyle {
        settings.activeTabIndicatorStyle
    }

    private var colorPalette: SidebarTabItemColorPalette {
        SidebarTabItemColorPalette(
            settings: settings,
            isActive: isActive,
            colorScheme: colorScheme,
            explicitRailColorHex: explicitRailColorHex
        )
    }

    private var explicitRailColorHex: String? {
        explicitRailColor != nil ? workspaceSnapshot.customColorHex : nil
    }

    private var openSidebarPullRequestLinksInCmuxBrowser: Bool {
        settings.openPullRequestLinksInCmuxBrowser
    }

    private var openSidebarPortLinksInCmuxBrowser: Bool {
        settings.openPortLinksInCmuxBrowser
    }

    private var showCloseButton: Bool {
        rowInteractionState.shouldShowCloseButton(
            canCloseWorkspace: canCloseWorkspace,
            shortcutHintModeActive: showsModifierShortcutHints || alwaysShowShortcutHints
        )
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "\(workspaceShortcutModifierSymbol)\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsModifierShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    private var remoteWorkspaceSidebarText: String? {
        guard tab.isRemoteWorkspace else { return nil }
        let trimmedTarget = tab.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTarget, !trimmedTarget.isEmpty {
            return trimmedTarget
        }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "Remote workspace")
    }

    private var copyableSidebarSSHError: String? {
        let fallbackTarget = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let trimmedDetail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.remoteConnectionState == .error || tab.remoteConnectionState == .suspended,
           let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: trimmedDetail
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = tab.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: statusValue
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch tab.remoteConnectionState {
        case .connected:
            return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .reconnecting:
            return String(localized: "remote.status.reconnecting", defaultValue: "Reconnecting")
        case .error:
            return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected:
            return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        case .suspended:
            return String(localized: "remote.status.suspended", defaultValue: "Unreachable")
        }
    }

    /// App-coupled sidebar row actions live on this adapter (see
    /// `SidebarTabItemActions`); the row constructs it from its own values,
    /// bindings, and closures and forwards each action to it.
    private var actions: SidebarTabItemActions {
        SidebarTabItemActions(
            tabManager: tabManager,
            notificationStore: notificationStore,
            tab: tab,
            index: index,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            setSelectionToTabs: setSelectionToTabs,
            openSidebarPullRequestLinksInCmuxBrowser: openSidebarPullRequestLinksInCmuxBrowser,
            openSidebarPortLinksInCmuxBrowser: openSidebarPortLinksInCmuxBrowser
        )
    }

    private func copyWorkspaceIdsToPasteboard(_ ids: [UUID], includeRefs: Bool = false) {
        actions.copyWorkspaceIdsToPasteboard(ids, includeRefs: includeRefs)
    }

    private func copyWorkspaceLinksToPasteboard(_ ids: [UUID]) {
        actions.copyWorkspaceLinksToPasteboard(ids)
    }

    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility {
        settings.visibleAuxiliaryDetails
    }

    private var workspaceSnapshotPresentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: settings.showsWorkspaceDescription,
            usesVerticalBranchLayout: sidebarBranchVerticalLayout,
            showsGitBranch: sidebarShowGitBranch,
            usesViewportAwarePath: sidebarUsesLastSegmentPath,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails
        )
    }

    var body: some View {
#if DEBUG
        let _ = { sidebarLazyContractProbe.workspaceRowBody?() }()
#endif
        let workspaceSnapshot = self.workspaceSnapshot
        let palette = colorPalette
        let closeWorkspaceTooltip = String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close Workspace")
        let protectedWorkspaceTooltip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation."
        )
        let closeButtonTooltip = workspaceSnapshot.isPinned
            ? protectedWorkspaceTooltip
            : KeyboardShortcutSettings.Action.closeWorkspace.tooltip(closeWorkspaceTooltip)
        let accessibilityHintText = String(localized: "sidebar.workspace.accessibilityHint", defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.")
        let moveUpActionText = String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up")
        let moveDownActionText = String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down")
        let latestNotificationSubtitle = latestNotificationText
        let conversationMessageSubtitle = !settings.hidesAllDetails && settings.iMessageModeEnabled
            ? workspaceSnapshot.latestConversationMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            : nil
        let effectiveSubtitle = latestNotificationSubtitle ?? conversationMessageSubtitle
        let detailVisibility = visibleAuxiliaryDetails
        let titleLineLimit = settings.wrapsWorkspaceTitles ? Self.maxWrappedTitleLines : 1
        let displayedTitle = workspaceSnapshot.title.sidebarBoundedDisplayString(
            maxDisplayedLines: titleLineLimit,
            maxDisplayedCharacters: Self.maxDisplayedTitleCharacters
        )
        let scaledUnreadBadgeSize = 16 * palette.fontScale
        let scaledCloseButtonHitSize = max(16, 16 * palette.fontScale)
        let scaledCloseButtonWidth = max(
            SidebarTrailingAccessoryWidthPolicy().closeButtonWidth,
            scaledCloseButtonHitSize
        )

        let rowContent = SidebarWorkspaceRowContent(
            snapshot: workspaceSnapshot,
            detailVisibility: detailVisibility,
            isActive: palette.usesInvertedActiveForeground,
            unreadCount: unreadCount,
            unreadBadgeFillColor: palette.activeUnreadBadgeFillColor,
            unreadBadgeTextColor: palette.activeUnreadBadgeTextColor,
            unreadBadgeDiameter: scaledUnreadBadgeSize,
            hasMemoryWarning: hasMemoryWarning,
            memoryWarningTooltip: String(
                localized: "sidebar.memoryWarning.tooltip",
                defaultValue: "A pane in this workspace is using a lot of memory"
            ),
            memoryWarningAccessibilityLabel: String(
                localized: "sidebar.memoryWarning.accessibilityLabel",
                defaultValue: "High memory warning"
            ),
            pinnedTooltip: protectedWorkspaceTooltip,
            displayedTitle: displayedTitle,
            titleColor: palette.activePrimaryTextColor,
            titleFontWeight: palette.titleFontWeight,
            titleLineLimit: titleLineLimit,
            isTitleEditing: isEditing,
            pinIconColor: palette.activeSecondaryColor(0.8),
            closeButtonColor: palette.activeSecondaryColor(0.7),
            showsCloseButton: canCloseWorkspace,
            closeButtonVisible: showCloseButton,
            closeButtonWidth: scaledCloseButtonWidth,
            closeButtonHitSize: scaledCloseButtonHitSize,
            closeButtonTooltip: closeButtonTooltip,
            onClose: {
                #if DEBUG
                cmuxDebugLog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=button")
                #endif
                tabManager.closeWorkspaceWithConfirmation(tab)
            },
            descriptionActiveForegroundColor: palette.activeSecondaryColor(0.84),
            descriptionDebugLog: Self.sidebarDescriptionDebugLog,
            subtitle: effectiveSubtitle,
            subtitleColor: palette.activeSecondaryColor(0.8),
            showsRemoteSection: !settings.hidesAllDetails && sidebarShowSSH,
            remoteHostColor: palette.activeSecondaryColor(0.8),
            remoteStatusColor: palette.activeSecondaryColor(0.58),
            remoteReconnectColor: palette.activeSecondaryColor(0.9),
            remoteTopPadding: latestNotificationText == nil ? 1 : 2,
            onReconnect: {
                tab.reconnectRemoteConnection()
            },
            activeSecondaryColor: { palette.activeSecondaryColor($0) },
            progressTrackColor: palette.activeProgressTrackColor,
            progressFillColor: palette.activeProgressFillColor,
            branchSecondaryColor: palette.activeSecondaryColor(0.75),
            branchIconColor: palette.activeSecondaryColor(0.6),
            usesVerticalBranchLayout: sidebarBranchVerticalLayout,
            stacksBranchAndDirectory: sidebarStacksBranchAndDirectory,
            showsGitBranchIcon: sidebarShowGitBranchIcon,
            pullRequestForegroundColor: pullRequestForegroundColor,
            makesPullRequestsClickable: settings.makesPullRequestsClickable,
            fontScale: palette.fontScale,
            onFocus: { updateSelection() },
            pullRequestStatusLabel: { pullRequestStatusLabel($0) },
            pullRequestOpenTooltip: { title in
                String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open \(title)")
            },
            onOpenPullRequest: { openPullRequestLink($0) },
            portLabel: { SidebarPortDisplayText.label(for: $0) },
            portTooltip: { SidebarPortDisplayText.openTooltip(for: $0) },
            onOpenPort: { openPortLink($0) },
            editingTitleContent: {
                SidebarInlineRenameField(
                    initialText: renameDraft,
                    fontSize: GlobalFontMagnification.scaledSize(
                        palette.scaledFontSize(12.5),
                        percent: globalFontMagnificationPercent
                    ),
                    textColor: palette.selectedWorkspaceForegroundNSColor(opacity: 1.0),
                    accessibilityLabel: String(
                        localized: "sidebar.workspace.rename.field.accessibilityLabel",
                        defaultValue: "Rename workspace"
                    ),
                    placeholder: String(
                        localized: "commandPalette.rename.workspacePlaceholder",
                        defaultValue: "Workspace name"
                    ),
                    onCommit: { newName in
                        commitInlineRename(newName)
                    },
                    onCancel: {
                        cancelInlineRename()
                    }
                )
            }
        )
        // No implicit .animation(value:) on agent-mutable fields: animating a
        // row-height change interpolates the LazyVStack's measured height over
        // every frame of the 0.2s curve, and with dozens of agent sessions some
        // row is always animating, so the sidebar-wide layout re-runs at display
        // refresh rate (#5764 / #5845). Lazy rows must be height-stable after
        // they appear; content changes now apply in one discrete layout pass.
        //
        // Split into `let` bindings so the SwiftUI type-checker resolves the row
        // constructor and the long modifier chain in separate, smaller passes
        // (the combined expression exceeds its time budget after the merge).
        let decoratedRow = rowContent
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            SidebarWorkspaceRowBackground(
                fillColor: backgroundColor,
                borderColor: palette.activeBorderColor,
                borderLineWidth: palette.activeBorderLineWidth,
                showsLeadingRail: palette.showsLeadingRail,
                railColor: railColor
            )
        )
        .sidebarShortcutHintOverlay(
            text: showsWorkspaceShortcutHint ? workspaceShortcutLabel : nil,
            emphasis: palette.shortcutHintEmphasis,
            offsetX: sidebarShortcutHintXOffset,
            offsetY: sidebarShortcutHintYOffset,
            fontSize: palette.scaledFontSize(10)
        )
        .shortcutHintVisibilityAnimation(value: showsWorkspaceShortcutHint)
        .padding(.horizontal, 6)
        .background { SidebarRowHeightProbe { rowHeight = $0 } }

        let interactiveRow = decoratedRow
        .contentShape(Rectangle())
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay {
            SidebarWorkspaceRowHoverTracker(
                onPointerHoverChanged: { hovering in
                    rowInteractionState.setPointerHovering(hovering)
                },
                onMenuTrackingChanged: { tracking in
                    if tracking {
                        rowInteractionState.contextMenuTrackingDidBegin()
                    } else {
                        rowInteractionState.contextMenuTrackingDidEnd()
                    }
                }
            )
        }
        .overlay {
            MiddleClickCapture {
                #if DEBUG
                cmuxDebugLog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=middleClick")
                #endif
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        }
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: index == 0,
                rowSpacing: rowSpacing,
                accent: cmuxAccentColor()
            )
        }

        return interactiveRow
        .onAppear {
            refreshWorkspaceSnapshot(force: true)
            handleInlineRenameRequest(inlineRenameRequestToken)
        }
        .task(id: workspaceFinderDirectoryOpenRequest) {
            guard let request = workspaceFinderDirectoryOpenRequest else { return }
            await WorkspaceFinderDirectoryOpener.openInFinder(request.directoryURL)
            guard !Task.isCancelled, workspaceFinderDirectoryOpenRequest == request else { return }
            workspaceFinderDirectoryOpenRequest = nil
        }
        .onReceive(
            tab.sidebarImmediateObservationPublisher
                .receive(on: RunLoop.main)
        ) { _ in
            Self.logSidebarRowInvalidate(tab: tab, source: "immediate")
            refreshWorkspaceSnapshot()
        }
        .onReceive(
            tab.sidebarObservationPublisher
                .receive(on: RunLoop.main)
                // Prompt-time sidebar telemetry can arrive as a short burst
                // (pwd, branch, PR, shell state). Coalesce that burst so the
                // row redraws once with the settled state instead of blinking.
                .debounce(for: Self.workspaceObservationCoalesceInterval, scheduler: RunLoop.main)
        ) { _ in
            Self.logSidebarRowInvalidate(tab: tab, source: "debounced")
            refreshWorkspaceSnapshot()
        }
        .onChange(of: settings) { _ in
            refreshWorkspaceSnapshot(force: true)
        }
        .onChange(of: inlineRenameRequestToken) { _, token in
            handleInlineRenameRequest(token)
        }
        .sidebarRowDragGate(isEditing: isEditing, onDragStart)
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegateFactory(rowHeight))
        .onDrop(of: BonsplitTabTransferPasteboard.dropContentTypes, delegate: SidebarBonsplitTabDropDelegate(
            targetWorkspaceId: tab.id,
            host: SidebarTabReorderHost(tabManager: tabManager),
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        ))
        .onTapGesture {
            if !isEditing {
                updateSelection()
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard !isEditing else { return }
                beginInlineRename()
            }
        )
        .safeHelp(workspaceSnapshot.title)
        .modifier(SidebarRowAccessibilityModifier(
            isEditing: isEditing,
            label: accessibilityTitle,
            hint: accessibilityHintText,
            moveUpLabel: moveUpActionText,
            moveDownLabel: moveDownActionText,
            onMoveUp: { moveBy(-1) },
            onMoveDown: { moveBy(1) }
        ))
        .contextMenu {
            SidebarTabItemContextMenu(
                data: workspaceContextMenuData,
                actions: workspaceContextMenuActions,
                onMenuAppear: {
                    rowInteractionState.contextMenuDidAppear()
                    contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
                    contextMenuState.pendingWorkspaceSnapshot = nil
                    onContextMenuAppear()
                },
                onMenuDisappear: {
                    rowInteractionState.contextMenuDidDisappear()
                    onContextMenuDisappear()
                    flushDeferredWorkspaceObservationInvalidation()
                }
            )
        }
    }

    private func handleInlineRenameRequest(_ token: Int?) {
        guard let token, handledInlineRenameRequestToken != token else { return }
        handledInlineRenameRequestToken = token
        onInlineRenameRequestHandled()
        beginInlineRename()
    }

    private func beginInlineRename() {
        updateSelection()
        renameDraft = workspaceSnapshot.title
        renameBaselineHadUserCustomTitle = tab.effectiveCustomTitleSource == .user
        isEditing = true
    }

    private func commitInlineRename(_ newName: String) {
        if let title = SidebarInlineRenameCommit().titleToCommit(
            draft: newName,
            baseline: renameDraft,
            baselineHadUserCustomTitle: renameBaselineHadUserCustomTitle
        ) {
            tabManager.setCustomTitle(tabId: tab.id, title: title)
        }
        isEditing = false
    }

    private func cancelInlineRename() {
        isEditing = false
    }

    private func refreshWorkspaceSnapshot(force: Bool = false) {
        let nextSnapshot = makeWorkspaceSnapshot()
        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: workspaceSnapshotStorage,
            next: nextSnapshot,
            force: force,
            contextMenuVisible: rowInteractionState.contextMenuVisible
        )

        if workspaceSnapshotStorage != decision.workspaceSnapshotStorage {
            workspaceSnapshotStorage = decision.workspaceSnapshotStorage
        }
        if contextMenuState.pendingWorkspaceSnapshot != decision.pendingWorkspaceSnapshot {
            contextMenuState.pendingWorkspaceSnapshot = decision.pendingWorkspaceSnapshot
        }
        if contextMenuState.hasDeferredWorkspaceObservationInvalidation != decision.hasDeferredWorkspaceObservationInvalidation {
            contextMenuState.hasDeferredWorkspaceObservationInvalidation = decision.hasDeferredWorkspaceObservationInvalidation
        }
    }

    private func flushDeferredWorkspaceObservationInvalidation() {
        guard contextMenuState.hasDeferredWorkspaceObservationInvalidation else { return }
        contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
        if let pendingSnapshot = contextMenuState.pendingWorkspaceSnapshot {
            workspaceSnapshotStorage = pendingSnapshot
        }
        contextMenuState.pendingWorkspaceSnapshot = nil
    }

    private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    private func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }

    /// Immutable snapshot of every label, id, flag, and submenu list rendered by
    /// the lifted ``SidebarWorkspaceContextMenu``. Computed once per body eval so
    /// the package menu never reads a live tab-manager/app-delegate store.
    private var workspaceContextMenuData: SidebarWorkspaceContextMenuData {
        let workspaceSnapshot = self.workspaceSnapshot
        let targetIds = contextMenuWorkspaceIds
        let isMulti = targetIds.count > 1
        let shouldPin = contextMenuPinState?.pinned ?? !tab.isPinned
        let reconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        let disconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        let pinLabel = shouldPin
            ? contextMenuLabel(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : contextMenuLabel(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        let closeLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        let markReadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        let markUnreadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        let clearLatestNotificationLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
            isMulti: isMulti)
        let copyWorkspaceIDLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs"),
            single: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
            isMulti: isMulti)
        let copyWorkspaceLinkLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceLinks", defaultValue: "Copy Workspace Links"),
            single: String(localized: "contextMenu.copyWorkspaceLink", defaultValue: "Copy Workspace Link"),
            isMulti: isMulti)
        let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let editWorkspaceDescriptionShortcut = KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
        let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        let groupSelectedShortcut = KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
        let groupInputs = workspaceGroupMenuInputs(targetIds: targetIds)
        let palette = WorkspaceTabColorSettings().palette().map { entry in
            SidebarWorkspaceColorMenuItem(id: entry.id, name: entry.name, hex: entry.hex)
        }
        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowMoveTargets = (AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? [])
            .map { target in
                SidebarWindowMoveMenuItem(
                    windowId: target.windowId,
                    label: target.label,
                    isCurrentWindow: target.isCurrentWindow
                )
            }

        return SidebarWorkspaceContextMenuData(
            targetIds: targetIds,
            isMulti: isMulti,
            pinLabel: pinLabel,
            pinEnabled: contextMenuPinState != nil,
            groups: groupInputs.groups,
            eligibleGroupTargetIds: groupInputs.eligibleTargetIds,
            allTargetsInSameGroupId: groupInputs.allTargetsInSameGroupId,
            hasAnyGroupedTarget: groupInputs.hasAnyGroupedTarget,
            groupSelectedShortcutKey: groupSelectedShortcut.keyEquivalent,
            groupSelectedShortcutModifiers: groupSelectedShortcut.eventModifiers,
            renameShortcutKey: renameWorkspaceShortcut.keyEquivalent,
            renameShortcutModifiers: renameWorkspaceShortcut.eventModifiers,
            hasCustomTitle: tab.hasCustomTitle,
            editDescriptionShortcutKey: editWorkspaceDescriptionShortcut.keyEquivalent,
            editDescriptionShortcutModifiers: editWorkspaceDescriptionShortcut.eventModifiers,
            hasCustomDescription: tab.hasCustomDescription,
            hasRemoteContextMenuTargets: !remoteContextMenuWorkspaceIds.isEmpty,
            reconnectLabel: reconnectLabel,
            disconnectLabel: disconnectLabel,
            allRemoteTargetsConnecting: allRemoteContextMenuTargetsConnecting,
            allRemoteTargetsDisconnected: allRemoteContextMenuTargetsDisconnected,
            hasCustomColor: tab.customColor != nil,
            colorPalette: palette,
            copyableSidebarSSHError: workspaceSnapshot.copyableSidebarSSHError,
            isFirstRow: index == 0,
            isLastRow: index >= tabManager.tabs.count - 1,
            windowMoveTargets: windowMoveTargets,
            closeShortcutKey: closeWorkspaceShortcut.keyEquivalent,
            closeShortcutModifiers: closeWorkspaceShortcut.eventModifiers,
            closeLabel: closeLabel,
            closeOthersDisabled: tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count,
            markReadLabel: markReadLabel,
            markUnreadLabel: markUnreadLabel,
            clearLatestNotificationLabel: clearLatestNotificationLabel,
            canMarkRead: notificationStore.canMarkWorkspaceRead(forTabIds: targetIds),
            canMarkUnread: notificationStore.canMarkWorkspaceUnread(forTabIds: targetIds),
            hasLatestNotifications: hasLatestNotifications(in: targetIds),
            copyWorkspaceIDLabel: copyWorkspaceIDLabel,
            copyWorkspaceLinkLabel: copyWorkspaceLinkLabel,
            canShowInFinder: workspaceSnapshot.finderDirectoryPath != nil
        )
    }

    /// The closures the lifted context menu invokes. Each encapsulates the
    /// app-coupled mutation the legacy inline button performed.
    private var workspaceContextMenuActions: SidebarWorkspaceContextMenuActions {
        SidebarWorkspaceContextMenuActions(
            colorSwatchImage: { hex in
                coloredCircleImage(color: tabColorSwatchColor(for: hex))
            },
            onPin: {
                guard let contextMenuPinState else {
                    NSSound.beep()
                    return
                }
                let result = WorkspaceActionDispatcher.performPinAction(contextMenuPinState, in: tabManager)
                if result.changedWorkspaceIds.isEmpty {
                    refreshWorkspaceSnapshot(force: true)
                }
                syncSelectionAfterMutation()
            },
            onNewGroup: { ids in
                promptNewWorkspaceGroup(workspaceIds: ids)
            },
            onMoveToGroup: { ids, groupId in
                for id in ids {
                    tabManager.addWorkspaceToGroup(workspaceId: id, groupId: groupId)
                }
            },
            onRemoveFromGroup: { ids in
                for id in ids {
                    tabManager.removeWorkspaceFromGroup(workspaceId: id)
                }
            },
            onRename: { beginInlineRename() },
            onRemoveCustomName: { tabManager.clearCustomTitle(tabId: tab.id) },
            onEditDescription: { beginWorkspaceDescriptionEditFromContextMenu() },
            onClearDescription: { tabManager.clearCustomDescription(tabId: tab.id) },
            onReconnect: {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.reconnectRemoteConnection()
                }
            },
            onDisconnect: {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.disconnectRemoteConnection(clearConfiguration: false)
                }
            },
            onApplyColor: { hex, ids in
                applyTabColor(hex, targetIds: ids)
            },
            onChooseCustomColor: { ids in
                promptCustomColor(targetIds: ids)
            },
            onCopySshError: { error in
                WorkspaceSurfaceIdentifierClipboardText.copy(error)
            },
            onMoveUp: { moveBy(-1) },
            onMoveDown: { moveBy(1) },
            onMoveToTop: { ids in
                tabManager.moveTabsToTop(Set(ids))
                syncSelectionAfterMutation()
            },
            onMoveToNewWindow: { ids in
                moveWorkspacesToNewWindow(ids)
            },
            onMoveToWindow: { ids, windowId in
                moveWorkspaces(ids, toWindow: windowId)
            },
            onClose: { ids in
                closeTabs(ids, allowPinned: true)
            },
            onCloseOthers: { ids in
                closeOtherTabs(ids)
            },
            onCloseBelow: { closeTabsBelow(tabId: tab.id) },
            onCloseAbove: { closeTabsAbove(tabId: tab.id) },
            onMarkRead: { ids in markTabsRead(ids) },
            onMarkUnread: { ids in markTabsUnread(ids) },
            onClearLatestNotifications: { ids in clearLatestNotifications(ids) },
            onCopyWorkspaceIds: { ids in copyWorkspaceIdsToPasteboard(ids) },
            onCopyWorkspaceLinks: { ids in copyWorkspaceLinksToPasteboard(ids) },
            onShowInFinder: {
                let url = workspaceSnapshot.finderDirectoryPath
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                workspaceFinderDirectoryOpenRequest = WorkspaceFinderDirectoryOpenRequest(directoryURL: url)
            }
        )
    }

    private var backgroundColor: Color {
        let style = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            isActive: isActive,
            isMultiSelected: isMultiSelected,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme,
            sidebarSelectionColorHex: colorPalette.sidebarSelectionColorHex
        )
        guard let color = style.color else { return .clear }
        return Color(nsColor: color).opacity(style.opacity)
    }

    private var railColor: Color {
        explicitRailColor ?? .clear
    }

    private var explicitRailColor: Color? {
        guard let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme
        ) else {
            return nil
        }
        return Color(nsColor: railColor).opacity(0.95)
    }

    private func tabColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings().displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    private var accessibilityTitle: String {
        String(localized: "accessibility.workspacePosition", defaultValue: "\(workspaceSnapshot.title), workspace \(index + 1) of \(accessibilityWorkspaceCount)")
    }

    private func moveBy(_ delta: Int) {
        actions.moveBy(delta)
    }

    private func updateSelection() {
        actions.updateSelection()
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        actions.closeTabs(targetIds, allowPinned: allowPinned)
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        actions.closeOtherTabs(targetIds)
    }

    private func closeTabsBelow(tabId: UUID) {
        actions.closeTabsBelow(tabId: tabId)
    }

    private func closeTabsAbove(tabId: UUID) {
        actions.closeTabsAbove(tabId: tabId)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        actions.markTabsRead(targetIds)
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        actions.markTabsUnread(targetIds)
    }

    private func clearLatestNotifications(_ targetIds: [UUID]) {
        actions.clearLatestNotifications(targetIds)
    }

    private func hasLatestNotifications(in targetIds: [UUID]) -> Bool {
        actions.hasLatestNotifications(in: targetIds)
    }

    private func syncSelectionAfterMutation() {
        actions.syncSelectionAfterMutation()
    }

    private var remoteStateHelpText: String {
        let target = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tab.remoteConnectionState {
        case .connected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connected",
                    defaultValue: "Remote connected to %@"
                ),
                locale: .current,
                target
            )
        case .connecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connecting",
                    defaultValue: "Remote connecting to %@"
                ),
                locale: .current,
                target
            )
        case .reconnecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.reconnecting",
                    defaultValue: "Remote reconnecting to %@"
                ),
                locale: .current,
                target
            )
        case .error:
            if let detail, !detail.isEmpty {
                return String(
                    format: String(
                        localized: "sidebar.remote.help.errorWithDetail",
                        defaultValue: "Remote error for %@: %@"
                    ),
                    locale: .current,
                    target,
                    detail
                )
            }
            return String(
                format: String(
                    localized: "sidebar.remote.help.error",
                    defaultValue: "Remote error for %@"
                ),
                locale: .current,
                target
            )
        case .disconnected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.disconnected",
                    defaultValue: "Remote disconnected from %@"
                ),
                locale: .current,
                target
            )
        case .suspended:
            return String(
                format: String(
                    localized: "sidebar.remote.help.suspended",
                    defaultValue: "SSH host %@ is unreachable. Automatic reconnect is paused — use Reconnect to retry."
                ),
                locale: .current,
                target
            )
        }
    }

    private func makeWorkspaceSnapshot() -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let detailVisibility = visibleAuxiliaryDetails
        let orderedPanelIds: [UUID]? = (detailVisibility.showsBranchDirectory || detailVisibility.showsPullRequests)
            ? tab.sidebarOrderedPanelIds()
            : nil

        // Gather the ordered branch/directory/pull-request projections from live
        // workspace state, gated exactly as the row's layout requires, then hand
        // them as plain value arrays to the snapshot builder, which performs all
        // formatting and derivation. The gating below is the only place these
        // reads happen, so a hidden detail never pays for its projection.
        let branches: [SidebarGitBranchState] = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  sidebarShowGitBranch,
                  let orderedPanelIds else {
                return []
            }
            return tab.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        }()
        let directories: [String] = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return tab.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        }()
        let directoryEntries: [SidebarBranchOrdering.BranchDirectoryEntry] = {
            guard detailVisibility.showsBranchDirectory,
                  sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return tab.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        }()
        let pullRequests: [SidebarPullRequestState] = {
            guard detailVisibility.showsPullRequests, let orderedPanelIds else { return [] }
            return tab.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds)
        }()

        let inputs = SidebarWorkspaceSnapshotBuilder.RowInputs(
            title: tab.title,
            customDescription: tab.customDescription,
            isPinned: tab.isPinned,
            customColorHex: tab.customColor,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            showsRemoteReconnectAffordance: tab.remoteConnectionState == .suspended
                || tab.remoteConnectionState == .disconnected,
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestConversationMessage: tab.latestConversationMessage,
            metadataEntries: detailVisibility.showsMetadata ? tab.sidebarStatusEntriesInDisplayOrder() : [],
            metadataBlocks: detailVisibility.showsMetadata ? tab.sidebarMetadataBlocksInDisplayOrder() : [],
            latestLog: detailVisibility.showsLog ? tab.logEntries.last : nil,
            progress: detailVisibility.showsProgress ? tab.progress : nil,
            listeningPorts: detailVisibility.showsPorts ? tab.listeningPorts : [],
            mediaActivity: SidebarWorkspaceSnapshotBuilder.MediaActivity(
                isPlayingAudio: tab.browserMediaActivity.isPlayingAudio,
                isUsingMicrophone: tab.browserMediaActivity.isUsingMicrophone,
                isUsingCamera: tab.browserMediaActivity.isUsingCamera
            )
        )

        return SidebarWorkspaceSnapshotBuilder.snapshot(
            presentationKey: workspaceSnapshotPresentationKey,
            branches: branches,
            directoryEntries: directoryEntries,
            directories: directories,
            pullRequests: pullRequests,
            settings: settings,
            flags: inputs,
            finderDirectoryPath: WorkspaceFinderDirectoryResolver.path(for: tab)
        )
    }

    private func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        actions.moveWorkspaces(workspaceIds, toWindow: windowId)
    }

    private func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        actions.moveWorkspacesToNewWindow(workspaceIds)
    }

    // latestNotificationText is now passed as a parameter from the parent view
    // to avoid subscribing to notificationStore changes in every TabItemView.

    private var pullRequestForegroundColor: Color {
        isActive ? colorPalette.activeSecondaryColor(0.75) : .secondary
    }

    private func openPullRequestLink(_ url: URL) {
        actions.openPullRequestLink(url)
    }

    private func openPortLink(_ port: Int) {
        actions.openPortLink(port)
    }

    private func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    private func applyTabColor(_ hex: String?, targetIds: [UUID]) {
        actions.applyTabColor(hex, targetIds: targetIds)
    }

    private func promptCustomColor(targetIds: [UUID]) {
        actions.promptCustomColor(targetIds: targetIds)
    }

    private func showInvalidColorAlert(_ value: String) {
        actions.showInvalidColorAlert(value)
    }

    private func beginWorkspaceDescriptionEditFromContextMenu() {
        actions.beginWorkspaceDescriptionEditFromContextMenu()
    }
}

/// Immutable, equatable snapshot of the group list a row's "Move to Group"
/// submenu can offer. Computed once per parent body eval and passed into
/// each TabItemView so the row's `==` covers group changes (renames, adds,
/// deletes) — the row's snapshot-boundary rule forbids reading
/// `tabManager.workspaceGroups` from inside the contextMenu builder.
/// Lifted to `CmuxSidebar.SidebarTabDragPayload`; this typealias keeps the
/// unqualified `SidebarTabDragPayload` spelling resolving for app-target
/// consumers (ContentView drop wiring and `DragOverlayRoutingPolicy`).
typealias SidebarTabDragPayload = CmuxSidebar.SidebarTabDragPayload

/// Lifted to `CmuxCore.SidebarSelection`; this typealias keeps the unqualified
/// `SidebarSelection` spelling resolving for app-target consumers.
typealias SidebarSelection = CmuxCore.SidebarSelection

// Command-palette list-host witnesses that touch ContentView's private state
// stay here; the `CommandPaletteListHost` conformance and its non-private
// witnesses live in ContentView+CommandPaletteHosting.swift.
extension ContentView {
    func commandPaletteListSyncDebugState() {
        syncCommandPaletteDebugStateForObservedWindow()
    }

    func commandPaletteListScheduleResultsRefresh(
        query: String?,
        force: Bool,
        preservePendingActivation: Bool
    ) {
        scheduleCommandPaletteResultsRefresh(
            query: query,
            forceSearchCorpusRefresh: force,
            preservePendingActivation: preservePendingActivation
        )
    }

    func commandPaletteListRunResolvedActivation(_ activation: CommandPaletteResolvedActivation) {
        runCommandPaletteResolvedActivation(activation)
    }
}

// Command-palette lifecycle-host witnesses that touch ContentView's private
// state stay here; the `CommandPaletteLifecycleHost` conformance and its
// non-private witnesses live in ContentView+CommandPaletteHosting.swift.
extension ContentView {
    var commandPaletteLifecycleIsPresented: Bool { isCommandPalettePresented }

    func commandPaletteLifecycleSetPresented(_ value: Bool) {
        isCommandPalettePresented = value
    }

    func commandPaletteLifecycleCaptureFocusRestoreTarget() {
        if let panelContext = focusedPanelContext {
            commandPaletteRestoreFocusTarget = CommandPaletteRestoreFocusTarget(
                workspaceId: panelContext.workspace.id,
                panelId: panelContext.panelId,
                intent: panelContext.panel.captureFocusIntent(in: observedWindow)
            )
        } else {
            commandPaletteRestoreFocusTarget = nil
        }
    }

    func commandPaletteLifecycleCurrentRestoreFocusTarget() -> CommandPaletteRestoreFocusTarget? {
        commandPaletteRestoreFocusTarget
    }

    func commandPaletteLifecycleClearRestoreFocusTarget() {
        commandPaletteRestoreFocusTarget = nil
    }

    func commandPaletteLifecycleRequestFocusRestore(target: CommandPaletteRestoreFocusTarget) {
        requestCommandPaletteFocusRestore(target: target)
    }

    func commandPaletteLifecycleRefreshCachedDefaultTerminalStatus() {
        refreshCachedDefaultTerminalStatus(refreshSearchCorpusIfPresented: false)
    }

    func commandPaletteLifecycleRefreshUsageHistory() {
        commandPalettePresentation.refreshUsageHistory()
    }

    func commandPaletteLifecycleCancelSearch() {
        cancelCommandPaletteSearch()
    }

    func commandPaletteLifecycleCancelSearchIndexBuild() {
        cancelCommandPaletteSearchIndexBuild()
    }

    func commandPaletteLifecycleCancelForkableAgentAvailabilityProbe() {
        cancelCommandPaletteForkableAgentAvailabilityProbe()
    }

    func commandPaletteLifecycleSetShouldFocusWorkspaceDescriptionEditor(_ value: Bool) {
        commandPaletteShouldFocusWorkspaceDescriptionEditor = value
    }

    func commandPaletteLifecycleClearSearchFocused() {
        isCommandPaletteSearchFocused = false
    }

    func commandPaletteLifecycleClearRenameFocused() {
        isCommandPaletteRenameFocused = false
    }

    func commandPaletteLifecycleClearTerminalOpenTargetAvailability() {
        commandPaletteTerminalOpenTargetAvailability = []
    }

    func commandPaletteLifecycleScheduleResultsRefresh(forceSearchCorpusRefresh: Bool) {
        scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: forceSearchCorpusRefresh)
    }

    func commandPaletteLifecycleSyncOverlayCommandListState() {
        syncCommandPaletteOverlayCommandListState()
    }

    func commandPaletteLifecycleResetSearchFocus() {
        resetCommandPaletteSearchFocus()
    }

    func commandPaletteLifecycleClearFirstResponderAndBrowserFocus() {
        if let window = observedWindow {
            _ = window.makeFirstResponder(nil)
        }
    }

    func commandPaletteLifecycleSyncDebugState() {
        syncCommandPaletteDebugStateForObservedWindow()
    }

    func commandPaletteLifecycleObservedWindowDebugSummary() -> String {
#if DEBUG
        (observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow).commandPaletteWindowDebugSummary
#else
        ""
#endif
    }
}

extension ContentView: CommandPaletteEditFlowHost {
    var commandPaletteEditFlowIsPresented: Bool { isCommandPalettePresented }

    var commandPaletteEditFlowDefaultWorkspaceDescriptionHeight: CGFloat {
        CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
    }

    func commandPaletteEditFlowSelectedWorkspaceRenameTarget() -> CommandPaletteRenameTarget? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspace.id),
            currentName: workspaceDisplayName(workspace)
        )
    }

    func commandPaletteEditFlowFocusedTabRenameTarget() -> CommandPaletteRenameTarget? {
        guard let panelContext = focusedPanelContext else { return nil }
        let panelName = panelDisplayName(
            workspace: panelContext.workspace,
            panelId: panelContext.panelId,
            fallback: panelContext.panel.displayTitle
        )
        return CommandPaletteRenameTarget(
            kind: .tab(workspaceId: panelContext.workspace.id, panelId: panelContext.panelId),
            currentName: panelName
        )
    }

    func commandPaletteEditFlowSelectedWorkspaceDescriptionTarget() -> CommandPaletteWorkspaceDescriptionTarget? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return CommandPaletteWorkspaceDescriptionTarget(
            workspaceId: workspace.id,
            currentDescription: workspace.customDescription ?? ""
        )
    }

    func commandPaletteEditFlowBeep() {
        NSSound.beep()
    }

    func commandPaletteEditFlowSetShouldFocusWorkspaceDescriptionEditor(_ shouldFocus: Bool) {
        commandPaletteShouldFocusWorkspaceDescriptionEditor = shouldFocus
    }

    func commandPaletteEditFlowResetRenameFocus() {
        resetCommandPaletteRenameFocus()
    }

    func commandPaletteEditFlowResetWorkspaceDescriptionFocus() {
        resetCommandPaletteWorkspaceDescriptionFocus()
    }

    func commandPaletteEditFlowSyncDebugState() {
        syncCommandPaletteDebugStateForObservedWindow()
    }

    func commandPaletteEditFlowPresent() {
        presentCommandPalette(initialQuery: Self.commandPaletteQueryScopePolicy.commandsPrefix)
    }

    func commandPaletteEditFlowDismiss() {
        dismissCommandPalette()
    }

    func commandPaletteEditFlowSetWorkspaceTitle(workspaceId: UUID, title: String?) {
        tabManager.setCustomTitle(tabId: workspaceId, title: title)
    }

    func commandPaletteEditFlowSetTabTitle(workspaceId: UUID, panelId: UUID, title: String?) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return false
        }
        workspace.setPanelCustomTitle(panelId: panelId, title: title)
        return true
    }

    func commandPaletteEditFlowDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog(message())
#endif
    }
}
