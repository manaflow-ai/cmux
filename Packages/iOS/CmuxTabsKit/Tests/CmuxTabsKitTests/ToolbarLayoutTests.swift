#if os(iOS)
@testable import CmuxTabsKit
import CoreGraphics
import Testing

/// Where the page toolbar sits (`TabsKitTheme.Metrics.barEdge`). Leo 2026-11-23: "we keep the
/// "safari" esque thing. but we move it to the top", so Back to the workspaces is one tap away
/// while the composer at the bottom has the keyboard up.
@MainActor
struct ToolbarLayoutTests {
    private let size = CGSize(width: 402, height: 874)
    private let safeTop: CGFloat = 62
    private let safeBottom: CGFloat = 34
    private let keyboard: CGFloat = 336

    private func metrics(_ edge: TabsKitBarEdge) -> TabsKitTheme.Metrics {
        var m = TabsKitTheme.Metrics()
        m.barEdge = edge
        return m
    }

    private func layout(_ edge: TabsKitBarEdge, keyboard: CGFloat = 0, bar: ChromeState.Bar = .expanded,
                        editing: Bool = false) -> ToolbarLayout {
        ToolbarLayout.make(metrics: metrics(edge), size: size, safeTop: safeTop, safeBottom: safeBottom, keyboard: keyboard,
                           bar: bar, editing: editing, splitBack: false, labelWidth: 69)
    }

    /// The default stays Safari's bottom bar.
    @Test func defaultEdgeIsTheBottom() {
        #expect(TabsKitTheme.Metrics().barEdge == .bottom)
        let l = layout(.bottom)
        #expect(l.capsule.minY > size.height / 2)
    }

    /// A top bar sits right under the status bar: back, address and tabs in one row.
    @Test func topBarSitsUnderTheStatusBar() {
        let l = layout(.top)
        #expect(l.back.minY == safeTop + TabsKitTheme.Metrics().topBarGap)
        #expect(l.capsule.minY == l.back.minY)
        #expect(l.right.minY == l.back.minY)
        #expect(l.back.maxY < size.height / 4)
    }

    /// The keyboard never moves or hides the top bar: Back is on screen and above the
    /// keyboard with the composer focused (the softlock Leo hit was Back behind the keyboard).
    @Test func keyboardLeavesTheTopBarInPlace() {
        let rest = layout(.top), typing = layout(.top, keyboard: keyboard)
        #expect(rest.back == typing.back)
        #expect(typing.back.maxY < size.height - keyboard)
        // The bottom bar, for contrast, is under the keyboard while it is up.
        let bottom = layout(.bottom, keyboard: keyboard)
        #expect(bottom.back.minY > size.height - keyboard)
    }

    /// Editing the address keeps the field in the top row, even with the keyboard up.
    @Test func editingStaysInTheTopRow() {
        let l = layout(.top, keyboard: keyboard, editing: true)
        #expect(l.capsule.minY == layout(.top).capsule.minY)
    }

    /// Collapsed, the pill rides just under the status bar, not at the screen bottom.
    @Test func collapsedPillIsAtTheTop() {
        let l = layout(.top, bar: .collapsed)
        #expect(l.capsule.maxY < safeTop + 48)
    }

    /// The content inset is on the bar's edge: under a top bar the page starts below it.
    @Test func contentInsetFollowsTheEdge() {
        let top = ToolbarLayout.barInset(metrics: metrics(.top), size: size, safeTop: safeTop, safeBottom: safeBottom)
        #expect(top == layout(.top).capsule.maxY + 8)
        let bottom = ToolbarLayout.barInset(metrics: metrics(.bottom), size: size, safeTop: safeTop, safeBottom: safeBottom)
        #expect(bottom == size.height - layout(.bottom).capsule.minY + 8)
    }
}
#endif
