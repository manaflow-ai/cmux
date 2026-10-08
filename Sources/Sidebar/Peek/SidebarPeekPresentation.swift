import AppKit
import CmuxSidebar
import SwiftUI

/// Presents the already-mounted sidebar subtree either flush in the layout or
/// as a floating card, without rebuilding it.
///
/// The whole point is that the two modes share one mounted subtree. cmux keeps
/// the AppKit workspace table alive behind a zero-width shell while the sidebar
/// is hidden (see `retainsDefaultAppKitSidebarWhenHidden` in `ContentView`), so
/// revealing it is a frame and opacity change, never a cold start. Peek rides
/// on that: the reveal has no table to build, which is what lets it be
/// instant instead of merely fast.
struct SidebarPeekPresentation: ViewModifier {
    /// Whether the sidebar should be drawn at all, from any cause: docked
    /// open, floating open, or temporarily revealed by peek.
    let isRevealed: Bool
    /// Whether to draw as a detached card rather than a flush pane.
    ///
    /// True whenever the sidebar is not taking layout width. Peek is a card by
    /// nature: it is a temporary reveal over content that did not move aside
    /// for it, so it draws as one even when the persisted mode is docked.
    let rendersAsCard: Bool
    /// The sidebar's resolved width.
    let width: CGFloat
    /// Whether a dismissal should skip the exit slide. True when the card
    /// is being superseded by the docked pane: the fixed sidebar replaces it
    /// in place, and a card gliding off underneath reads as a ghost.
    var dismissesInstantly: Bool = false
    /// The card's legibility tint (alpha included), resolved from the same
    /// appearance policy that paints the docked ground.
    var panelTint: Color = Color(nsColor: .windowBackgroundColor).opacity(0.52)
    /// The card's glass material, matching the docked ground's. Nil when the
    /// card's window is blurred by the compositor instead.
    var panelGlassMaterial: NSVisualEffectView.Material? = .popover
    /// The material's alpha, matching the docked ground's frost thickness so
    /// the floating card is exactly as see-through as the docked pane.
    var panelGlassOpacity: Double = 1.0
    /// Card geometry for floating mode.
    let panelMetrics: SidebarPeekPanelMetrics
    /// Acquires and releases the pointer hold as the pointer crosses the panel.
    let onPanelHoverChange: (Bool) -> Void
    /// False until the card first appears. The panel is mounted lazily, so
    /// it can arrive already revealed (switching to floating); gating on
    /// this keeps that first reveal a slide instead of a pop.
    @State private var cardHasAppeared = false

    private var showsCard: Bool {
        isRevealed && cardHasAppeared
    }

    /// Outer width including the card's leading inset, so floating and docked
    /// place the list's leading edge identically.
    private var floatingWidth: CGFloat {
        width + panelMetrics.leadingInset
    }

    func body(content: Content) -> some View {
        if rendersAsCard {
            SidebarPeekPanelChrome(
                metrics: panelMetrics,
                tint: panelTint,
                glassMaterial: panelGlassMaterial,
                glassOpacity: panelGlassOpacity
            ) {
                content.frame(width: width, alignment: .leading)
            }
            .frame(width: floatingWidth, alignment: .leading)
            // Slide from just behind the window edge rather than from zero
            // width. Animating the frame would re-lay-out every row on every
            // frame of the reveal; translating a laid-out subtree does not.
            .offset(x: showsCard ? 0 : -floatingWidth)
            .opacity(showsCard ? 1 : 0)
            .allowsHitTesting(showsCard)
            .accessibilityHidden(!showsCard)
            .onHover(perform: onPanelHoverChange)
            .onAppear { cardHasAppeared = true }
            // The exit is its own curve: a reveal wants a touch of arrival
            // settle, but a dismissal should read as the panel leaving the
            // screen, fast and without ceremony.
            .animation(
                showsCard
                    ? SidebarPeekMotion.reveal
                    : (dismissesInstantly ? nil : SidebarPeekMotion.dismiss),
                value: showsCard
            )
        } else {
            // Hidden, the pane keeps its full width, parked just past the
            // window's leading edge: its rows never re-lay out, and a toggle
            // slide (which translates the content root on the render server,
            // see SidebarToggleAnimator) carries it in and out as it is.
            content
                .frame(width: width, alignment: .leading)
                .clipped()
                .offset(x: isRevealed ? 0 : -width)
                .allowsHitTesting(isRevealed)
                .accessibilityHidden(!isRevealed)
        }
    }
}

/// The motion curves the peek panel uses.
enum SidebarPeekMotion {
    /// Reveal and dismissal.
    ///
    /// A spring rather than an ease so an interrupted reveal (pointer leaves
    /// mid-animation) retargets from wherever the panel currently is instead of
    /// snapping. `bounce` is zero: this is a panel arriving, not a toy.
    static let reveal = Animation.spring(response: 0.21, dampingFraction: 0.9)

    /// Dismissal: faster than the reveal and fully damped, so the panel
    /// slides off the edge rather than lingering or bouncing on its way out.
    static let dismiss = Animation.spring(response: 0.2, dampingFraction: 1.0)

    /// Switching between docked and floating.
    ///
    /// Slower than the reveal because the terminal reflows with it, and a fast
    /// reflow of a full screen of text reads as a flicker.
    static let modeChange = Animation.spring(response: 0.38, dampingFraction: 0.9)
}

extension View {
    /// Applies ``SidebarPeekPresentation``.
    func sidebarPeekPresentation(
        isRevealed: Bool,
        rendersAsCard: Bool,
        width: CGFloat,
        panelMetrics: SidebarPeekPanelMetrics = .default,
        onPanelHoverChange: @escaping (Bool) -> Void
    ) -> some View {
        modifier(SidebarPeekPresentation(
            isRevealed: isRevealed,
            rendersAsCard: rendersAsCard,
            width: width,
            panelMetrics: panelMetrics,
            onPanelHoverChange: onPanelHoverChange
        ))
    }
}
