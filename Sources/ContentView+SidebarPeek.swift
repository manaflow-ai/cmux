import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSidebar
import Bonsplit
import CmuxSettingsUI
import SwiftUI

extension Notification.Name {
    /// Posted by the titlebar accessory as the pointer enters or leaves the
    /// sidebar toggle button. userInfo: ["hovering": Bool].
    static let cmuxSidebarToggleHoverChanged = Notification.Name("cmux.sidebarToggleHoverChanged")
}

extension View {
    /// Broadcasts hover over the titlebar's sidebar toggle, which pre-reveals
    /// the peek card while the pointer rests on it (Aside behaviour).
    /// ContentView owns the peek state, so the button only broadcasts.
    func broadcastsSidebarToggleHover() -> some View {
        onHover { hovering in
            NotificationCenter.default.post(
                name: .cmuxSidebarToggleHoverChanged,
                object: nil,
                userInfo: ["hovering": hovering]
            )
        }
    }
}

extension NSView {
    /// While the floating sidebar card is up, the pointer over its rows is
    /// geometrically over the terminal too. Terminal surfaces call this from
    /// `resetCursorRects` so they keep the card's arrow instead of an I-beam.
    func cmuxYieldsCursorRectsToSidebarCard() -> Bool {
        guard window?.cmuxSuppressesTerminalCursorRects == true else { return false }
        addCursorRect(bounds, cursor: .arrow)
        return true
    }
}

extension ContentView {
    /// Whether the sidebar should be drawn, from any cause.
    ///
    /// Peek is a third way to be on screen, alongside docked and floating.
    /// Anything gating on "is the sidebar showing" has to ask this, not
    /// `isVisible`, or it will treat a peeked sidebar as absent.
    var sidebarIsRevealed: Bool {
        sidebarState.isVisible || sidebarPeek.presentsPanel
    }

    /// Whether the sidebar draws as a detached card instead of a flush pane.
    ///
    /// Anything not taking layout width is a card. A peek is a card even when
    /// the persisted mode is docked, because the terminal did not move aside
    /// for it.
    var sidebarRendersAsCard: Bool {
        !sidebarState.occupiesLayout
    }

    /// Card geometry tuned to this window's chrome.
    ///
    /// The panel window itself already starts below the titlebar band (so the
    /// traffic lights stay clickable), which leaves the card needing only a
    /// small headroom inside it.
    var sidebarPeekPanelMetrics: SidebarPeekPanelMetrics {
        SidebarPeekPanelMetrics(
            leadingInset: 10,
            topInset: 6,
            bottomInset: 12,
            cornerRadius: 12,
            shadowRadius: 22,
            shadowOffsetY: 6,
            shadowOpacity: 0.34,
            borderWidth: 0.5
        )
    }

    /// The in-layout presentation for the sidebar pane.
    ///
    /// Flush-only: the layout hosts the sidebar exclusively while it occupies
    /// layout width. Every card presentation (peek, persistent floating) goes
    /// through the child panel window instead, because an in-layout card draws
    /// underneath the portal-hosted terminal.
    func sidebarPeekPresentationModifier(width: CGFloat) -> SidebarPeekPresentation {
        SidebarPeekPresentation(
            // The layout flag, not `isVisible`: a toggle moves the pane
            // before ContentView hears about it.
            isRevealed: sidebarState.occupiesLayout && sidebarLayout.docksSidebar,
            rendersAsCard: false,
            width: width,
            panelMetrics: sidebarPeekPanelMetrics,
            onPanelHoverChange: { _ in }
        )
    }

    /// Whether the floating card is currently the active sidebar presentation.
    var sidebarPanelCardIsRevealed: Bool {
        sidebarIsRevealed && sidebarRendersAsCard
    }

    /// Whether the floating card's child window should exist right now.
    ///
    /// A docked, visible sidebar never needs it, and that is the common
    /// typing setup: the card is a second full sidebar list, so keeping it
    /// mounted there was pure cost. It mounts as soon as a card can show
    /// (floating, or hidden docked with peek on), which is before the edge
    /// dwell or the titlebar hover can ask for a reveal, and unmounts on dock.
    var sidebarNeedsPeekPanel: Bool {
        sidebarState.presentationMode.needsPeekPanel(
            sidebarVisible: sidebarState.isVisible,
            peekEnabled: sidebarPeek.policy.isEnabled,
            peekPresenting: sidebarPeek.presentsPanel
        )
    }

    /// Zero-sized anchor owning the child panel window that floats the card
    /// above the terminal. Mounted from `sidebarPeekLifecycle` while
    /// `sidebarNeedsPeekPanel`.
    var sidebarPeekPanelHost: some View {
        SidebarWidthReader(layout: sidebarLayout) { width in
            SidebarPeekPanelBridge(
                contentWidth: width,
                metrics: sidebarPeekPanelMetrics,
                acceptsMouse: sidebarPanelCardIsRevealed,
                onKeyboardFocusChange: { hasFocus in
                    // Typing into a rename or checklist field in the card
                    // keeps the peek up even after the pointer wanders off.
                    if hasFocus {
                        sidebarPeek.acquire(.keyboardFocusInside)
                    } else {
                        sidebarPeek.release(.keyboardFocusInside)
                    }
                },
                content: AnyView(sidebarPeekCard(width: width))
            )
        }
        .frame(width: 0, height: 0)
    }

    /// The floating card's full content, built fresh on every ContentView
    /// update so the panel window tracks state without its own environment
    /// plumbing. The environment injection mirrors what AppDelegate gives
    /// ContentView's own hosting view: the child window's hosting view
    /// inherits none of it.
    func sidebarPeekCard(width: CGFloat) -> some View {
        let revealed = sidebarPanelCardIsRevealed
        let appearance = windowAppearanceSnapshot
        // The card wears the docked ground's exact wash: same resolved tint
        // (colour and alpha) and same material, so floating and docked read
        // as one surface in two positions. The tint-opacity slider moves
        // both together through this single resolution.
        var panelTint = Color(nsColor: .windowBackgroundColor).opacity(0.52)
        var panelGlassMaterial: NSVisualEffectView.Material? = .popover
        var panelGlassOpacity = 1.0
        if case let .sidebarMaterial(materialPolicy) = appearance.policy(for: .leftSidebar) {
            panelTint = Color(nsColor: materialPolicy.tintColor)
            // The compositor-glass path has no material: the docked ground
            // is blurred by the window. The card carries its own glass so the
            // blur moves with it (a window-level blur on the fixed panel
            // could not follow the slide).
            panelGlassMaterial = materialPolicy.material ?? .hudWindow
            panelGlassOpacity = materialPolicy.opacity
        }
        // `isPresented: true` keeps the panel's list live even while hidden:
        // suspending it on dismissal blanks the rows the moment the slide-out
        // starts, which reads as the panel vanishing instead of leaving.
        return sidebarView(
            isPresented: true,
            attachesFocusBoundary: false,
            usesCompactTopInset: true
        )
            .environment(\.colorScheme, appearance.sidebarContentColorScheme)
            .modifier(SidebarPeekPresentation(
                isRevealed: revealed,
                rendersAsCard: true,
                width: width,
                panelTint: panelTint,
                panelGlassMaterial: panelGlassMaterial,
                panelGlassOpacity: panelGlassOpacity,
                panelMetrics: sidebarPeekPanelMetrics,
                onPanelHoverChange: { isInside in
                    if isInside {
                        sidebarPeek.acquire(.pointerInsidePanel)
                    } else {
                        sidebarPeek.release(.pointerInsidePanel)
                    }
                }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(SidebarHostedEnvironment(contentView: self))
    }

    /// The environment ContentView's own hosting view gives the sidebar, for
    /// a sidebar hosted in its own NSHostingView (the docked pane's host, the
    /// peek card's window), which inherits none of it.
    func sidebarEnvironment<Content: View>(_ content: Content) -> some View {
        content.modifier(SidebarHostedEnvironment(contentView: self))
    }

    /// The invisible leading-edge strip that arms the hover-reveal.
    ///
    /// Armed whenever the sidebar is hidden, in either presentation mode. An
    /// earlier version required floating mode first, which made peek
    /// unreachable in practice: the mode toggle only appears on a *visible*
    /// sidebar, so a user who hid a docked sidebar had no way to reach either
    /// the toggle or the peek. Hiding the sidebar is the moment peek exists
    /// for.
    ///
    /// The strip removes its tracking area entirely when disarmed rather than
    /// ignoring callbacks, so a docked sidebar costs nothing.
    @ViewBuilder
    var sidebarPeekEdgeStrip: some View {
        SidebarPeekEdgeTrackingView(
            width: sidebarPeek.policy.edgeWidth,
            isEnabled: !sidebarState.isVisible && sidebarPeek.policy.isEnabled,
            onEnter: { sidebarPeek.pointerEnteredEdge() },
            onExit: { sidebarPeek.pointerExitedEdge() }
        )
        .frame(width: sidebarPeek.policy.edgeWidth)
        .frame(maxHeight: .infinity)
        .zIndex(1)
    }

    /// The peek machine's lifecycle around the sidebar layout: policy from
    /// Settings, docking and hiding retire a peek, the titlebar toggle's
    /// hover pre-reveals, plus the panel host and the edge strip.
    func sidebarPeekLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onAppear {
                sidebarToggleAnimator.install(
                    sidebarState: sidebarState,
                    layout: sidebarLayout,
                    window: { observedWindow },
                    // The Dock's terminals live in the moving portal and
                    // cannot be held still; toggle instantly there.
                    canSlide: {
                        retainsDefaultAppKitSidebarWhenHidden
                            && !(rightSidebarVisible && fileExplorerState.mode == .dock)
                    },
                    trailingStillWidth: { rightSidebarWidth },
                    isPeekPresenting: { sidebarPeek.presentsPanel }
                )
                sidebarPeek.setPolicy(SidebarCustomizationSettings.peekPolicy())
            }
            .onReceive(
                NotificationCenter.default
                    .publisher(for: UserDefaults.didChangeNotification)
                    .receive(on: RunLoop.main)
            ) { _ in
                // Settings-window edits land here. The equality guard
                // keeps the frequent defaults churn from rebuilding the
                // peek machine when nothing it cares about changed.
                let policy = SidebarCustomizationSettings.peekPolicy()
                if policy != sidebarPeek.policy {
                    sidebarPeek.setPolicy(policy)
                }
            }
            .onChange(of: sidebarState.occupiesLayout) { _, occupies in
                if occupies {
                    // Docking retires any active peek: the card handed
                    // its place to the fixed pane.
                    sidebarPeek.sidebarDocked()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cmuxSidebarToggleHoverChanged)) { note in
                // Aside behaviour: hovering the titlebar's sidebar toggle
                // pre-reveals the peek card, so the click lands on a
                // sidebar that is already gliding in. Routed through the
                // peek machine's edge events, so dwell, grace, and
                // dismissal all behave exactly like the screen-edge peek.
                guard let hovering = note.userInfo?["hovering"] as? Bool else { return }
                guard observedWindow?.isKeyWindow == true else { return }
                guard !sidebarState.isVisible, sidebarPeek.policy.isEnabled else { return }
                if hovering {
                    // A hover re-fired by the hide click itself is not a
                    // request to show; only an arrival after the window
                    // pre-reveals.
                    if let until = sidebarToggleHoverSuppressedUntil, Date() < until {
                        return
                    }
                    sidebarPeek.pointerEnteredActivationControl()
                } else {
                    sidebarPeek.pointerExitedEdge()
                }
            }
            .onChange(of: sidebarState.isVisible) { _, visible in
                guard !visible else { return }
                // Hiding retires any peek in flight and opens the hover
                // suppression window, so the card cannot flash over the
                // closing pane. The show direction is untouched.
                sidebarPeek.sidebarCollapsed()
                sidebarToggleHoverSuppressedUntil = Date().addingTimeInterval(0.3)
            }
            .background {
                // Zero-sized anchor that owns the floating card's child
                // window. The card cannot live in this tree: the portal
                // hosts every terminal surface above the window's SwiftUI
                // hosting view, so an in-tree card draws underneath the
                // terminal no matter its zIndex.
                if sidebarNeedsPeekPanel {
                    sidebarPeekPanelHost
                }
            }
            .overlay(alignment: .leading) {
                // Same slot and layering as the resizer overlay, which is
                // the proven way in this codebase to receive pointer
                // events over the portal-hosted terminal. A strip placed
                // inside the layout stack can end up beneath the terminal's
                // AppKit view and never see the pointer at all.
                sidebarPeekEdgeStrip
                    .zIndex(999)
            }
    }
}

/// Mirrors what AppDelegate injects into ContentView's hosting view.
struct SidebarHostedEnvironment: ViewModifier {
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    let sidebarState: SidebarState
    let sidebarSelectionState: SidebarSelectionState
    let fileExplorerState: FileExplorerState
    let cmuxConfigStore: CmuxConfigStore
    let sessionDragRegistry: SessionDragRegistry?
    let tabDragTransferRegistry: TabDragTransferRegistry?
    let settingsRuntime: SettingsRuntime?

    @MainActor
    init(contentView: ContentView) {
        tabManager = contentView.tabManager
        notificationStore = contentView.notificationStore
        sidebarState = contentView.sidebarState
        sidebarSelectionState = contentView.sidebarSelectionState
        fileExplorerState = contentView.fileExplorerState
        cmuxConfigStore = contentView.cmuxConfigStore
        sessionDragRegistry = contentView.sessionDragRegistryEnv
        tabDragTransferRegistry = contentView.tabDragTransferRegistryEnv
        settingsRuntime = contentView.settingsRuntimeEnv
    }

    func body(content: Content) -> some View {
        content
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)
            .environmentObject(fileExplorerState)
            .environmentObject(cmuxConfigStore)
            .environment(\.sessionDragRegistry, sessionDragRegistry)
            .environment(\.tabDragTransferRegistry, tabDragTransferRegistry)
            .environment(\.settingsRuntime, settingsRuntime)
            .cmuxFontMagnificationEnvironment()
    }
}
