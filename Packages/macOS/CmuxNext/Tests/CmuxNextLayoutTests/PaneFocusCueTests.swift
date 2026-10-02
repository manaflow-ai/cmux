import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// `appearance.focusIndicator`: the layout tells every pane's chrome how
/// strongly to draw (subtle in unfocused panes when it marks tabs) and draws
/// the ring only when it marks the border.
@MainActor
struct PaneFocusCueTests {
    private final class ChromeView: NSView, PaneContentChrome {
        var paneHeaderHeight: CGFloat { 20 }
        var onPaneHeaderHeightChange: (() -> Void)?
        var emphasis: ChromeEmphasis?
        func setPaneContentCornerRadius(_ radius: CGFloat) {}
        func setChromeEmphasis(_ emphasis: ChromeEmphasis, animated: Bool) { self.emphasis = emphasis }
    }

    private final class Provider: LayoutPaneContentProvider {
        var views: [PaneID: ChromeView] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let view = ChromeView()
            views[pane] = view
            return view
        }
    }

    private func layout(_ indicator: FocusIndicator, panes: Int = 2, drawsLines: Bool = true) -> (LayoutRootView, NSWindow, Provider) {
        let tree: SplitNode = panes == 1 ? .leaf("a") : .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .splits(tree))], activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        var style = LayoutStyle()
        style.focusIndicator = indicator
        style.inactiveTabStyle = .tonal
        style.inactiveTabStrength = 0.3
        style.drawsLines = drawsLines
        model.baseStyle = style
        let provider = Provider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: frame)
        window.contentView = container
        container.addSubview(view)
        view.frame = container.bounds
        container.layoutSubtreeIfNeeded()
        return (view, window, provider)
    }

    @Test func bothMarksTheRingAndTheOtherPanesTabs() {
        let (view, window, provider) = layout(.both)
        defer { window.close() }
        #expect(provider.views["a"]?.emphasis == .full)
        #expect(provider.views["b"]?.emphasis == .subtle(.tonal, strength: 0.3))
        #expect(view.context.hosts["a"]?.chrome.showsRing == true)
    }

    @Test func tabsAloneDrawsNoRing() {
        let (view, window, provider) = layout(.tabs)
        defer { window.close() }
        #expect(provider.views["b"]?.emphasis == .subtle(.tonal, strength: 0.3))
        #expect(view.context.hosts["a"]?.chrome.showsRing == false)
    }

    @Test func borderAloneKeepsEveryTabStrip() {
        let (view, window, provider) = layout(.border)
        defer { window.close() }
        #expect(provider.views["b"]?.emphasis == .full)
        #expect(view.context.hosts["a"]?.chrome.showsRing == true)
    }

    @Test func noneMarksNothingAndOnePaneIsAlwaysFull() {
        let (view, window, provider) = layout(.none)
        defer { window.close() }
        #expect(provider.views["b"]?.emphasis == .full)
        #expect(view.context.hosts["a"]?.chrome.showsRing == false)
        let (_, single, only) = layout(.both, panes: 1)
        defer { single.close() }
        #expect(only.views["a"]?.emphasis == .full)
    }

    /// With `appearance.borders` none the unfocused panes' dim stands in for
    /// the ring only when the indicator asked for the border alone.
    @Test func withoutLinesTheDimReplacesOnlyARequestedBorder() {
        for (indicator, dims) in [(FocusIndicator.border, true), (.both, false), (.tabs, false), (.none, false)] {
            let (view, window, _) = layout(indicator, drawsLines: false)
            defer { window.close() }
            #expect((view.context.hosts["b"]?.chrome.dimOpacity ?? 0 > 0) == dims, "\(indicator)")
            #expect(view.context.hosts["a"]?.chrome.dimOpacity == 0, "\(indicator)")
        }
    }
}
