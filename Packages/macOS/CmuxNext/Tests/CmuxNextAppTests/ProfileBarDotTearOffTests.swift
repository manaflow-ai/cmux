import AppKit
@testable import CmuxNextSidebar
import Testing

/// A space dot dragged out of the window opens that space in a new window (Lawrence 14223,
/// plans/cmux-next/spaces-overhaul-DESIGN.md rule 4), the action Open Space in New Window runs
/// (`SidebarIntent.openProfileInNewWindow`, `space.openInNewWindow`). It never reorders, and a drop on
/// the footer band still reorders as before. Real mouse events on the bar, as `ProfileBarDotReorderTests`.
@MainActor @Suite(.serialized) struct ProfileBarDotTearOffTests {
    static let keys = (0..<3).map { ProfileKey("space\($0)") }

    final class Bar {
        let model = SidebarModel()
        let view: ProfileBarView
        let window: NSWindow
        var intents: [SidebarIntent] = []

        init() {
            model.profiles = ProfileBarDotTearOffTests.keys.enumerated().map { SidebarProfile(id: $1, name: "Space \($0)") }
            model.activeProfileID = ProfileBarDotTearOffTests.keys[0]
            view = ProfileBarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.refresh()
            model.onIntent = { [weak self] intent in
                self?.intents.append(intent)
                self?.model.apply(intent)
                self?.view.refresh()
            }
        }

        func center(_ index: Int) -> NSPoint {
            let slot = view.slotRects()[index]
            return NSPoint(x: slot.midX, y: slot.midY)
        }

        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func drag(_ index: Int, through path: [NSPoint]) {
            view.mouseDown(with: event(.leftMouseDown, center(index)))
            for point in path { view.mouseDragged(with: event(.leftMouseDragged, point)) }
            view.mouseUp(with: event(.leftMouseUp, path.last ?? center(index)))
        }

        var opens: [SidebarIntent] { intents.filter { if case .openProfileInNewWindow = $0 { true } else { false } } }
        var reorders: [SidebarIntent] { intents.filter { if case .reorderProfile = $0 { true } else { false } } }
    }

    @Test func aDotDroppedOutsideTheWindowOpensItsSpaceInANewWindow() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let start = bar.center(1)
        bar.drag(1, through: [NSPoint(x: start.x + 6, y: start.y), NSPoint(x: start.x + 20, y: start.y + 120), NSPoint(x: start.x + 40, y: start.y + 300)])
        #expect(bar.opens == [.openProfileInNewWindow(Self.keys[1])], "\(bar.intents)")
        #expect(bar.reorders.isEmpty, "a tear-off also reordered: \(bar.intents)")
        #expect(bar.model.profiles.map(\.id) == Self.keys, "the space left the original window's strip")
    }

    /// The pointer left and came back over the band: a reorder, no new window.
    @Test func aDotThatComesBackToTheBandStillReorders() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let start = bar.center(0), last = bar.center(2)
        bar.drag(0, through: [NSPoint(x: start.x + 6, y: start.y), NSPoint(x: start.x, y: start.y + 300), NSPoint(x: last.x + 4, y: last.y)])
        #expect(bar.opens.isEmpty, "\(bar.intents)")
        #expect(bar.reorders == [.reorderProfile(Self.keys[0], index: 3)], "\(bar.intents)")
    }

    /// A drop on the band opens nothing.
    @Test func aDropOnTheBandOpensNoWindow() {
        let bar = Bar()
        defer { bar.window.orderOut(nil) }
        let y = bar.center(2).y
        bar.drag(2, through: [NSPoint(x: bar.center(2).x - 6, y: y), NSPoint(x: bar.center(1).x - 2, y: y)])
        #expect(bar.opens.isEmpty, "\(bar.intents)")
        #expect(bar.reorders == [.reorderProfile(Self.keys[2], index: 1)], "\(bar.intents)")
    }
}
