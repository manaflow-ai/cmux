import AppKit
import Testing
@testable import CmuxNextLayout

/// Splits and closes change the layout in one frame: target frames apply
/// inside the update call and no display-link animation is scheduled.
/// Ratio and width changes keep their spring.
@MainActor
struct InstantSplitTests {
    private let size = CGSize(width: 1000, height: 600)

    private func splitTree(ratio: Double = 0.5) -> SplitNode {
        .split("s1", axis: .horizontal, ratio: ratio, a: .leaf("a"), b: .leaf("b"))
    }

    private func makeView(_ layout: ScreenLayout, provider: RecordingProvider) -> (ScreenContentView, LayoutModel) {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: layout)])
        let context = LayoutViewContext(model: model, provider: provider)
        let view = ScreenContentView(screenID: "s", layout: layout, context: context)
        view.frame = CGRect(origin: .zero, size: size)
        return (view, model)
    }

    private func expectAtTargets(_ view: ScreenContentView, sourceLocation: SourceLocation = #_sourceLocation) {
        for (pane, target) in view.geometry.panes {
            #expect(view.displayedFrame(of: pane) == target, "pane \(pane)", sourceLocation: sourceLocation)
            #expect(view.context.hosts[pane]?.frame == target, "host \(pane)", sourceLocation: sourceLocation)
            #expect(view.context.hosts[pane]?.alphaValue == 1, "alpha \(pane)", sourceLocation: sourceLocation)
        }
    }

    @Test func splitAppliesTargetFramesSynchronously() {
        let provider = RecordingProvider()
        let (view, _) = makeView(.splits(.leaf("a")), provider: provider)
        let needsFrames = view.update(layout: .splits(splitTree()), animated: true)
        #expect(!needsFrames)
        #expect(view.geometry.panes.count == 2)
        expectAtTargets(view)
    }

    @Test func splitOfEitherAxisAndSideIsInstant() {
        for axis in [SplitAxis.horizontal, .vertical] {
            for newFirst in [false, true] {
                let provider = RecordingProvider()
                let (view, _) = makeView(.splits(.leaf("a")), provider: provider)
                let tree: SplitNode = newFirst
                    ? .split("s1", axis: axis, ratio: 0.5, a: .leaf("b"), b: .leaf("a"))
                    : .split("s1", axis: axis, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
                #expect(!view.update(layout: .splits(tree), animated: true))
                expectAtTargets(view)
            }
        }
    }

    @Test func closeAppliesAndReleasesSynchronously() {
        let provider = RecordingProvider()
        let (view, _) = makeView(.splits(splitTree()), provider: provider)
        let needsFrames = view.update(layout: .splits(.leaf("a")), animated: true)
        #expect(!needsFrames)
        #expect(provider.released == ["b"])
        #expect(view.context.hosts["b"] == nil)
        #expect(view.displayedFrame(of: "a") == view.geometry.panes["a"])
        expectAtTargets(view)
    }

    @Test func splitInsideAColumnIsInstant() {
        let provider = RecordingProvider()
        let before = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5, root: .leaf("a"))])
        let after = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5, root: splitTree())])
        let (view, _) = makeView(before, provider: provider)
        #expect(!view.update(layout: after, animated: true))
        expectAtTargets(view)
    }

    @Test func ratioChangeKeepsItsSpring() {
        let provider = RecordingProvider()
        let (view, _) = makeView(.splits(splitTree()), provider: provider)
        #expect(view.update(layout: .splits(splitTree(ratio: 0.3)), animated: true))
    }

    @Test func rootViewSchedulesNoDisplayLinkForASplit() async {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .splits(.leaf("a")))])
        let provider = RecordingProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard view.driver.isAttached, !view.context.reduceMotion else { return }

        model.apply(screens: [LayoutScreen(id: "s", name: "", layout: .splits(splitTree()))])
        for _ in 0..<1000 where view.frame(of: "b") == nil { await Task.yield() }
        let screen = view.screenViews["s"]!
        #expect(!view.driver.isRunning)
        expectAtTargets(screen)

        model.apply(screens: [LayoutScreen(id: "s", name: "", layout: .splits(.leaf("a")))])
        for _ in 0..<1000 where view.frame(of: "b") != nil { await Task.yield() }
        #expect(!view.driver.isRunning)
        #expect(provider.released == ["b"])
        expectAtTargets(screen)
        withExtendedLifetime(provider) {}
    }
}

private final class RecordingProvider: LayoutPaneContentProvider {
    var released: [PaneID] = []
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
    func releaseContentView(_ view: NSView, for pane: PaneID) { released.append(pane) }
}
