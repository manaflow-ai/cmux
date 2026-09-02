import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSidebar
import SwiftUI

extension Notification.Name {
    /// Posted by the titlebar accessory as the pointer enters or leaves the
    /// sidebar toggle button. userInfo: ["hovering": Bool].
    static let cmuxSidebarToggleHoverChanged = Notification.Name("cmux.sidebarToggleHoverChanged")
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
            isRevealed: sidebarState.occupiesLayout,
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

    /// Zero-sized anchor owning the child panel window that floats the card
    /// above the terminal. Mounted from `contentAndSidebarLayout`.
    var sidebarPeekPanelHost: some View {
        let appearance = windowAppearanceSnapshot
        return SidebarWidthReader(layout: sidebarLayout) { width in
            SidebarPeekPanelBridge(
                contentWidth: width,
                metrics: sidebarPeekPanelMetrics,
                acceptsMouse: sidebarPanelCardIsRevealed,
                // The card's own window gets the same compositor blur as the
                // docked ground, so floating and docked glass match exactly.
                // Never while docked: the panel then sits over the docked
                // pane's rows and would blur them as they slide in.
                glassBlurRadius: appearance.usesCompositorGlass && !sidebarState.occupiesLayout
                    ? appearance.sidebarSettings.effectiveCompositorBlurRadius
                    : nil,
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
            // A nil material is the compositor-glass path: the card's window
            // is blurred by the compositor, so no effect view is drawn.
            panelGlassMaterial = materialPolicy.material
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
                // Docking supersedes the card in place: no exit slide.
                dismissesInstantly: sidebarState.occupiesLayout,
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
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)
            .environmentObject(fileExplorerState)
            .environmentObject(cmuxConfigStore)
            .environment(\.sessionDragRegistry, sessionDragRegistryEnv)
            .environment(\.tabDragTransferRegistry, tabDragTransferRegistryEnv)
            .environment(\.settingsRuntime, settingsRuntimeEnv)
            .cmuxFontMagnificationEnvironment()
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
}
