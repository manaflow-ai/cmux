import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// The focus ring, its glow and the attention ring are overlay-only: moving
/// focus, changing the ring's style, width or corners, and marking panes for
/// attention never change a pane frame, its content rect or the hosted
/// content's frame, in splits and in strip columns.
@MainActor
struct FocusRingNoShiftTests {
    private func makeRoot(_ layout: ScreenLayout, style: LayoutStyle) -> (LayoutRootView, NSWindow, NoShiftProvider) {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: layout)], activeScreenID: "s")
        model.followsDesignMetrics = false
        model.baseStyle = style
        let provider = NoShiftProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window, provider)
    }

    /// Every pane's displayed frame, content rect and hosted view frame.
    private func frames(_ view: LayoutRootView) -> [PaneID: [CGRect]] {
        var result: [PaneID: [CGRect]] = [:]
        for (pane, host) in view.context.hosts {
            result[pane] = [view.frame(of: pane) ?? .null, host.frame, host.contentRect, host.content.frame]
        }
        return result
    }

    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func check(_ layout: ScreenLayout, panes: [PaneID]) async {
        var style = LayoutStyle()
        style.panePadding = 4
        style.paneCornerRadius = 8
        let (view, window, provider) = makeRoot(layout, style: style)
        defer { window.close() }
        await settle { !view.driver.isRunning }
        let baseline = frames(view)
        #expect(baseline.count == panes.count)

        for ringStyle in [FocusRingStyle.ring, .glow, .none] {
            for width: CGFloat in [1, 8] {
                var next = style
                next.focusRing.style = ringStyle
                next.focusRing.width = width
                next.focusRing.cornerRadius = width == 8 ? 20 : nil
                next.focusRing.showsForSinglePane = true
                view.model.baseStyle = next
                for (index, pane) in panes.enumerated() {
                    view.model.focus(pane, source: .pointer)
                    view.model.attention = index.isMultiple(of: 2) ? [pane: AttentionMark(generation: UInt64(index + 1))] : [:]
                    await settle { view.context.hosts[pane]?.chrome.showsRing == (ringStyle != .none) }
                    await settle { !view.driver.isRunning }
                    #expect(frames(view) == baseline, "style \(ringStyle) width \(width) focus \(pane)")
                    #expect(view.context.hosts[pane]?.chrome.showsRing == (ringStyle != .none))
                }
            }
        }
        withExtendedLifetime(provider) {}
    }

    @Test func splitsNeverShiftWhenFocusOrRingChanges() async {
        let tree: SplitNode = .split("s1", axis: .horizontal, ratio: 0.5,
                                     a: .split("s2", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b")),
                                     b: .split("s3", axis: .vertical, ratio: 0.5, a: .leaf("c"), b: .leaf("d")))
        await check(.splits(tree), panes: ["a", "b", "c", "d"])
    }

    @Test func visibleColumnsNeverShiftWhenFocusOrRingChanges() async {
        let columns: ScreenLayout = .columns([
            LayoutColumn(id: "c1", width: 1.0 / 3.0, root: .leaf("a")),
            LayoutColumn(id: "c2", width: 1.0 / 3.0, root: .split("s", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))),
            LayoutColumn(id: "c3", width: 1.0 / 3.0, root: .leaf("d")),
        ])
        await check(columns, panes: ["a", "b", "c", "d"])
    }

    @Test func aSinglePaneShowsTheRingOnlyWhenAsked() async {
        var style = LayoutStyle()
        let (view, window, provider) = makeRoot(.splits(.leaf("a")), style: style)
        defer { window.close() }
        await settle { view.context.hosts["a"] != nil }
        #expect(view.context.hosts["a"]?.chrome.showsRing == false)
        style.focusRing.showsForSinglePane = true
        view.model.baseStyle = style
        await settle { view.context.hosts["a"]?.chrome.showsRing == true }
        #expect(view.context.hosts["a"]?.chrome.showsRing == true)
        style.focusRing.enabled = false
        view.model.baseStyle = style
        await settle { view.context.hosts["a"]?.chrome.showsRing == false }
        #expect(view.context.hosts["a"]?.chrome.showsRing == false)
        withExtendedLifetime(provider) {}
    }

    @Test func attentionRingShowsAndClears() async {
        let (view, window, provider) = makeRoot(.splits(.split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))), style: LayoutStyle())
        defer { window.close() }
        await settle { view.context.hosts["b"] != nil }
        view.model.attention = ["b": AttentionMark(generation: 1)]
        await settle { view.context.hosts["b"]?.chrome.showsAttention == true }
        #expect(view.context.hosts["b"]?.chrome.showsAttention == true)
        #expect(view.context.hosts["a"]?.chrome.showsAttention == false)
        view.model.attention = [:]
        await settle { view.context.hosts["b"]?.chrome.showsAttention == false }
        #expect(view.context.hosts["b"]?.chrome.showsAttention == false)
        withExtendedLifetime(provider) {}
    }
}

private final class NoShiftProvider: LayoutPaneContentProvider {
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}
