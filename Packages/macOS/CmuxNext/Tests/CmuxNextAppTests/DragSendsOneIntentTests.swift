import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A divider or column drag is local until it ends (perf-10x drag): the
/// layout follows every pointer move, and the App gets one intent, the
/// released value, so the daemon gets one command per drag.
@MainActor
@Suite(.closesItsWindows)
struct DragSendsOneIntentTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func aDividerDragOfManyMovesEmitsOnlyItsReleasedValue() async {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s",
                                                       layout: .splits(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))))],
                                activeScreenID: "s", focusedPane: "p1")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        guard let screen = root.screenViews["s"], let divider = screen.geometry.dividers.first(where: { $0.id == "x" }),
              let handle = screen.dividerViews[.split("x")] else {
            Issue.record("no divider")
            return
        }
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: screen.convert(CGPoint(x: x, y: divider.frame.midY), to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = divider.frame.midX
        handle.mouseDown(with: event(.leftMouseDown, start))
        var shown: [Double] = []
        for move in 1...60 {
            handle.mouseDragged(with: event(.leftMouseDragged, start + CGFloat(move) * 3))
            _ = root.advanceFrame(1.0 / 120)
            shown.append(model.screens[0].layout.ratio(of: "x") ?? 0)
        }
        #expect(intents.isEmpty)
        #expect(shown.last! > shown.first!)
        handle.mouseUp(with: event(.leftMouseUp, start + 180))
        #expect(intents.count == 1)
        guard case let .setSplitRatio(split, ratio, _, phase)? = intents.first else {
            Issue.record("expected one set-split-ratio, got \(intents)")
            return
        }
        #expect(split == "x" && phase == .ended)
        #expect(abs(ratio - (model.screens[0].layout.ratio(of: "x") ?? 0)) < 1e-9)
    }
}
