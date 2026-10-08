import AppKit
import CmuxSidebar
import SwiftUI

/// Presents the already-mounted sidebar subtree either flush in the layout or
/// as a floating card, without rebuilding it.
///
/// The whole point is that the two modes share one mounted subtree. cmux keeps
/// the AppKit workspace table alive and drawn while the sidebar is hidden
/// (see `retainsDefaultAppKitSidebarWhenHidden` in `ContentView` and
/// `SidebarDockedPaneHost`), so revealing it is a move, never a cold start. Peek rides
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
    /// The card's legibility tint (alpha included), resolved from the same
    /// appearance policy that paints the docked ground.
    var panelTint: Color = Color(nsColor: .windowBackgroundColor).opacity(0.52)
    /// The card's glass material, matching the docked ground's. Nil draws
    /// tint only.
    var panelGlassMaterial: NSVisualEffectView.Material? = .popover
    /// The material's alpha, matching the docked ground's frost thickness so
    /// the floating card is exactly as see-through as the docked pane.
    var panelGlassOpacity: Double = 1.0
    /// Card geometry for floating mode.
    let panelMetrics: SidebarPeekPanelMetrics
    /// Acquires and releases the pointer hold as the pointer crosses the panel.
    let onPanelHoverChange: (Bool) -> Void
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
            // Laid out where it rests. The panel host slides the whole card,
            // glass included, on the render server (see
            // SidebarPeekPanelWindowController), so the blur cannot trail it.
            .allowsHitTesting(isRevealed)
            .accessibilityHidden(!isRevealed)
            .onHover(perform: onPanelHoverChange)
        } else {
            // The pane keeps its full width and its slot whether shown or
            // hidden: its host parks it by drawing only (see
            // SidebarDockedPaneHost), and the toggle's slide carries it in
            // and out as it is.
            content
                .frame(width: width, alignment: .leading)
                .allowsHitTesting(isRevealed)
                .accessibilityHidden(!isRevealed)
        }
    }
}

/// The motion curves the peek panel uses.
enum SidebarPeekMotion {
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
