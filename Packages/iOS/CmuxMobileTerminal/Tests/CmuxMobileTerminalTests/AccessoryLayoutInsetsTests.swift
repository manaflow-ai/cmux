#if canImport(UIKit)
import CoreGraphics
import Testing

@testable import CmuxMobileTerminal

/// The accessory strip's leading/trailing insets align its controls with the
/// terminal's horizontal span, measured against the HOSTING BAR's own frame.
/// The regression here is the iPad split view: the toolbar is docked inside
/// the surface (its edges already flush with the terminal's), so re-applying
/// the terminal's window-space X as a leading inset stranded the whole
/// control row a sidebar-width from the strip's leading edge whenever the
/// sidebar was visible.
struct AccessoryLayoutInsetsTests {
    // iPad Pro 13" landscape: 1376x1032 window, 380pt sidebar, detail pane
    // hosting the terminal from x=380 to the right window edge.
    private static let windowBounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
    private static let splitTerminalFrame = CGRect(x: 380, y: 0, width: 996, height: 1032)

    @Test func dockedToolbarInsideSplitDetailPaneNeedsNoInset() {
        // Docked hosting: the bar spans exactly the terminal's width, so both
        // sides are already covered and the strip starts at the pane's leading
        // edge. Before the fix the left inset came back 380 (the sidebar
        // width), pushing dismiss/nub/composer/scroll a sidebar-width right.
        let insets = GhosttySurfaceView.accessoryLayoutInsets(
            terminalFrame: Self.splitTerminalFrame,
            toolbarFrame: Self.splitTerminalFrame,
            windowBounds: Self.windowBounds
        )
        #expect(insets.left == 0)
        #expect(insets.right == 0)
    }

    @Test func windowSpanningBarKeepsWindowEdgeMath() {
        // Keyboard-accessory hosting: the bar spans the window, so each side
        // insets by the span the terminal does not cover (the historical
        // behavior this helper must preserve).
        let insets = GhosttySurfaceView.accessoryLayoutInsets(
            terminalFrame: Self.splitTerminalFrame,
            toolbarFrame: Self.windowBounds,
            windowBounds: Self.windowBounds
        )
        #expect(insets.left == 380)
        #expect(insets.right == 0)
    }

    @Test func unhostedBarFallsBackToWindowBounds() {
        let insets = GhosttySurfaceView.accessoryLayoutInsets(
            terminalFrame: Self.splitTerminalFrame,
            toolbarFrame: nil,
            windowBounds: Self.windowBounds
        )
        #expect(insets.left == 380)
        #expect(insets.right == 0)
    }

    @Test func fullWidthTerminalIsUnchangedInEitherHosting() {
        // iPhone / compact: terminal spans the window, so both hostings agree
        // on zero and the fix cannot move anything on existing layouts.
        let phoneWindow = CGRect(x: 0, y: 0, width: 402, height: 874)
        for toolbarFrame in [phoneWindow, CGRect?.none] {
            let insets = GhosttySurfaceView.accessoryLayoutInsets(
                terminalFrame: phoneWindow,
                toolbarFrame: toolbarFrame,
                windowBounds: phoneWindow
            )
            #expect(insets.left == 0)
            #expect(insets.right == 0)
        }
    }

    @Test func partialCoverageInsetsOnlyTheUncoveredSpan() {
        // A bar wider than the terminal on both sides (e.g. a future hosting
        // that bleeds under the sidebar): each side insets by exactly the
        // uncovered span, never negative.
        let barFrame = CGRect(x: 300, y: 0, width: 1076, height: 44)
        let insets = GhosttySurfaceView.accessoryLayoutInsets(
            terminalFrame: Self.splitTerminalFrame,
            toolbarFrame: barFrame,
            windowBounds: Self.windowBounds
        )
        #expect(insets.left == 80)
        #expect(insets.right == 0)

        let narrowTerminal = CGRect(x: 380, y: 0, width: 500, height: 1032)
        let trailingGap = GhosttySurfaceView.accessoryLayoutInsets(
            terminalFrame: narrowTerminal,
            toolbarFrame: barFrame,
            windowBounds: Self.windowBounds
        )
        #expect(trailingGap.left == 80)
        #expect(trailingGap.right == 496)
    }
}
#endif
