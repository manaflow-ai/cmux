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
    /// Docked or floating.
    let mode: SidebarPresentationMode
    /// Whether the sidebar is docked open.
    let isDockedVisible: Bool
    /// Whether peek is currently presenting the floating panel.
    let isPeeking: Bool
    /// The sidebar's resolved width.
    let width: CGFloat
    /// Card geometry for floating mode.
    let panelMetrics: SidebarPeekPanelMetrics
    /// Acquires and releases the pointer hold as the pointer crosses the panel.
    let onPanelHoverChange: (Bool) -> Void

    /// Whether anything should be drawn at all.
    private var isPresented: Bool {
        switch mode {
        case .docked:
            return isDockedVisible
        case .floating:
            return isDockedVisible || isPeeking
        }
    }

    /// Outer width including the card's leading inset, so floating and docked
    /// place the list's leading edge identically.
    private var floatingWidth: CGFloat {
        width + panelMetrics.leadingInset
    }

    func body(content: Content) -> some View {
        switch mode {
        case .docked:
            content
                .frame(width: isPresented ? width : 0, alignment: .leading)
                .clipped()
                .allowsHitTesting(isPresented)
                .accessibilityHidden(!isPresented)
        case .floating:
            SidebarPeekPanelChrome(metrics: panelMetrics) {
                content.frame(width: width, alignment: .leading)
            }
            .frame(width: floatingWidth, alignment: .leading)
            // Slide from just behind the window edge rather than from zero
            // width. Animating the frame would re-lay-out every row on every
            // frame of the reveal; translating a laid-out subtree does not.
            .offset(x: isPresented ? 0 : -floatingWidth)
            .opacity(isPresented ? 1 : 0)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
            .onHover(perform: onPanelHoverChange)
            .animation(SidebarPeekMotion.reveal, value: isPresented)
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
    static let reveal = Animation.spring(response: 0.28, dampingFraction: 0.86)

    /// Switching between docked and floating.
    ///
    /// Slower than the reveal because the terminal reflows with it, and a fast
    /// reflow of a full screen of text reads as a flicker.
    static let modeChange = Animation.spring(response: 0.38, dampingFraction: 0.9)
}

extension View {
    /// Applies ``SidebarPeekPresentation``.
    func sidebarPeekPresentation(
        mode: SidebarPresentationMode,
        isDockedVisible: Bool,
        isPeeking: Bool,
        width: CGFloat,
        panelMetrics: SidebarPeekPanelMetrics = .default,
        onPanelHoverChange: @escaping (Bool) -> Void
    ) -> some View {
        modifier(SidebarPeekPresentation(
            mode: mode,
            isDockedVisible: isDockedVisible,
            isPeeking: isPeeking,
            width: width,
            panelMetrics: panelMetrics,
            onPanelHoverChange: onPanelHoverChange
        ))
    }
}
