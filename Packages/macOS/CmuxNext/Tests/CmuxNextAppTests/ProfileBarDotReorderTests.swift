import AppKit
@testable import CmuxNextSidebar
import Testing

/// The sidebar footer's space dots reorder by drag (unimplemented audit row 14): a dot dragged
/// along the footer band and dropped there moves its space with the same `move-profile` reorder
/// as the space menu's Move Left / Move Right (`SidebarIntent.reorderProfile`); a drop off the
/// band moves nothing, and a click still switches the space. Real mouse events on the bar.
@MainActor @Suite(.serialized) struct ProfileBarDotReorderTests {
    static let keys = (0..<3).map { ProfileKey("space\($0)") }

    /// A bar with three spaces (the first current) in a window, and the intents it sends.
    final class Bar {
        let model = SidebarModel()
        let view: ProfileBarView
        let window: NSWindow
        var intents: [SidebarIntent] = []

        init() {
            model.profiles = ProfileBarDotReorderTests.keys.enumerated().map { SidebarProfile(id: $1, name: "Space \($0)") }
            model.activeProfileID = ProfileBarDotReorderTests.keys[0]
            view = ProfileBarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.refresh()
            model.onIntent = { [weak self] intent in
                self?.intents.append(intent)
                self?.model.apply(intent) // the app applies a reorder at once (SidebarBridge)
                self?.view.refresh()
            }
        }

        /// The middle of space `index`'s dot, in the bar.
        func center(_ index: Int) -> NSPoint {
            let slot = view.slotRects()[index]
            return NSPoint(x: slot.midX, y: slot.midY)
        }

        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// Presses space `index`, drags through `path` (bar points) and releases at its end.
        func drag(_ index: Int, through path: [NSPoint]) {
            view.mouseDown(with: event(.leftMouseDown, center(index)))
            for point in path { view.mouseDragged(with: event(.leftMouseDragged, point)) }
            view.mouseUp(with: event(.leftMouseUp, path.last ?? center(index)))
        }

        var order: [ProfileKey] { model.profiles.map(\.id) }
        var reorders: [SidebarIntent] { intents.filter { if case .reorderProfile = $0 { true } else { false } } }
    }

    @Test func aDotDraggedPastTheLastDotMovesItsSpaceToTheEnd() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let last = bar.center(2)
        bar.drag(0, through: [NSPoint(x: bar.center(0).x + 6, y: last.y), NSPoint(x: bar.center(1).x + 2, y: last.y), NSPoint(x: last.x + 4, y: last.y)])
        #expect(bar.reorders == [.reorderProfile(Self.keys[0], index: 3)], "\(bar.intents)")
        #expect(bar.order == [Self.keys[1], Self.keys[2], Self.keys[0]])
        #expect(!bar.intents.contains { if case .switchProfile = $0 { true } else { false } }, "the drag also switched the space: \(bar.intents)")
    }

    /// The bug Lawrence hit (2026-10-27): no drag put a space first. The dragged dot stops at the
    /// first dot's center, and a dot only passed another once it went strictly beyond its center,
    /// so the first slot was out of reach.
    @Test(arguments: [1, 2])
    func aDotDraggedPastTheFirstDotMovesItsSpaceToTheStart(_ index: Int) {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let first = bar.center(0)
        bar.drag(index, through: [NSPoint(x: bar.center(index).x - 6, y: first.y), NSPoint(x: first.x - 40, y: first.y)])
        #expect(bar.reorders == [.reorderProfile(Self.keys[index], index: 0)], "\(bar.intents)")
        #expect(bar.order.first == Self.keys[index], "\(bar.order)")
    }

    /// The one `move-profile` index rule the drag and Move Left/Right/to Start/to End/to Position
    /// send (`ProfileBarLogic.moveInsertion`), over four spaces.
    @Test func everyReorderSendsTheSameInsertionIndex() {
        #expect(ProfileBarLogic.moveInsertion(from: 2, to: 0, count: 4) == 0) // to start
        #expect(ProfileBarLogic.moveInsertion(from: 1, to: 3, count: 4) == 4) // to end
        #expect(ProfileBarLogic.moveInsertion(from: 2, to: 1, count: 4) == 1) // left
        #expect(ProfileBarLogic.moveInsertion(from: 1, to: 2, count: 4) == 3) // right
        #expect(ProfileBarLogic.moveInsertion(from: 0, to: 0, count: 4) == nil, "already first: refused")
        #expect(ProfileBarLogic.moveInsertion(from: 0, to: 0, count: 4, allowsStay: true) == 0, "to position 1 when first: no-op")
        #expect(ProfileBarLogic.moveInsertion(from: 3, to: 4, count: 4) == nil, "past the end")
        #expect(ProfileBarLogic.moveInsertion(from: 0, to: -1, count: 4) == nil, "before the start")
    }

    /// While the dot sits on the first slot, the strip already shows it first.
    @Test func theStripPreviewsTheFirstSlotWhileTheDotIsThere() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let first = bar.center(0)
        bar.view.mouseDown(with: bar.event(.leftMouseDown, bar.center(2)))
        bar.view.mouseDragged(with: bar.event(.leftMouseDragged, NSPoint(x: first.x - 40, y: first.y)))
        #expect(bar.view.previewOrder == [Self.keys[2], Self.keys[0], Self.keys[1]])
        bar.view.mouseUp(with: bar.event(.leftMouseUp, NSPoint(x: first.x - 40, y: first.y)))
    }

    @Test func aDotDraggedLeftOneSlotMovesItsSpaceLeftLikeMoveLeft() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let y = bar.center(2).y
        bar.drag(2, through: [NSPoint(x: bar.center(2).x - 6, y: y), NSPoint(x: bar.center(1).x - 2, y: y)])
        // Move Left's insertion index for the third space (RoomHandlers.move: from - 1).
        #expect(bar.reorders == [.reorderProfile(Self.keys[2], index: 1)], "\(bar.intents)")
        #expect(bar.order == [Self.keys[0], Self.keys[2], Self.keys[1]])
    }

    /// While the dot moves, the strip shows the order a drop would give and the model keeps its own
    /// until the drop; off the band the strip shows the order unchanged.
    @Test func theOtherDotsMakeWayWhileTheDotMoves() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let y = bar.center(0).y
        bar.view.mouseDown(with: bar.event(.leftMouseDown, bar.center(0)))
        bar.view.mouseDragged(with: bar.event(.leftMouseDragged, NSPoint(x: bar.center(1).x + 2, y: y)))
        #expect(bar.view.previewOrder == [Self.keys[1], Self.keys[0], Self.keys[2]])
        #expect(bar.order == Self.keys, "the model moved before the drop")
        bar.view.mouseDragged(with: bar.event(.leftMouseDragged, NSPoint(x: bar.center(1).x + 2, y: y - 200)))
        #expect(bar.view.previewOrder == Self.keys, "off the footer band the strip still shows a move")
        bar.view.mouseUp(with: bar.event(.leftMouseUp, NSPoint(x: bar.center(1).x + 2, y: y - 200)))
        #expect(bar.reorders.isEmpty, "\(bar.intents)")
    }

    /// The drop target is the footer band: released far above it, nothing moves.
    @Test func aDotDroppedOffTheFooterBandMovesNothing() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let last = bar.center(2)
        bar.drag(0, through: [NSPoint(x: last.x + 4, y: last.y), NSPoint(x: last.x + 4, y: last.y - 200)])
        #expect(bar.reorders.isEmpty, "\(bar.intents)")
        #expect(bar.order == Self.keys)
    }

    @Test func aClickOnADotStillSwitchesTheSpace() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        bar.drag(1, through: [])
        #expect(bar.intents == [.switchProfile(Self.keys[1])], "\(bar.intents)")
        #expect(bar.order == Self.keys)
    }
}
