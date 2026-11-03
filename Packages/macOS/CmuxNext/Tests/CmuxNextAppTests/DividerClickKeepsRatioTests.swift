import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A press and release on a split divider with no drag between them changes
/// nothing. Before, the release saved the ratio the divider was drawn at:
/// with a pane held at its minimum width in a narrow window, one click
/// replaced the stored ratio, so widening the window no longer brought the
/// person's split back (found by the 2026-10-21 QA spree, live in a tagged
/// build). A real drag still saves its ratio on release.
@MainActor
@Suite(.closesItsWindows)
struct DividerClickKeepsRatioTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var ratios: [(Double, LayoutGesturePhase)] = []

        init() {
            _ = NSApplication.shared
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in
                if case .setSplitRatio(_, let ratio, _, let phase) = intent { ratios.append((ratio, phase)) }
            }
        }

        var handle: DividerHandleView {
            get throws { try #require(root.screenViews["s"]?.dividerViews[.split("x")]) }
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func center() throws -> CGPoint {
            let handle = try handle
            return handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        }
    }

    @Test func aClickWithNoDragSavesNoRatio() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let handle = try harness.handle
        let point = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, point))
        handle.mouseUp(with: harness.event(.leftMouseUp, point))
        #expect(harness.ratios.isEmpty, "a click on the divider sent \(harness.ratios)")
    }

    @Test func aDragStillSavesItsRatioOnRelease() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let handle = try harness.handle
        let start = try harness.center()
        let end = CGPoint(x: start.x - 200, y: start.y)
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        handle.mouseDragged(with: harness.event(.leftMouseDragged, end))
        handle.mouseUp(with: harness.event(.leftMouseUp, end))
        let ended = harness.ratios.filter { $0.1 == .ended }
        #expect(ended.count == 1)
        #expect((ended.first?.0 ?? 1) < 0.5)
    }
}
