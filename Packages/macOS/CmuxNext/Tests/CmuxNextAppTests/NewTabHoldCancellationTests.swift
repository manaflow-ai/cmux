import AppKit
@testable import CmuxNextTabs
import Testing

@MainActor @Suite(.serialized) struct NewTabHoldCancellationTests {
    @Test func anUninterruptedHoldOpensExactlyOneMenu() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let task = try fixture.press()
        await fixture.gate.waitUntilStarted()
        await fixture.gate.release()
        await task.value
        #expect(fixture.presentations == 1)
        fixture.strip.endNewTabPress(at: fixture.buttonPoint)
        #expect(fixture.intents.isEmpty)
    }

    @Test func draggingOutsideCancelsTheHoldButKeepsReleaseInside() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let task = try fixture.press()
        await fixture.gate.waitUntilStarted()
        fixture.strip.mouseDragged(with: try fixture.event(.leftMouseDragged, at: NSPoint(x: 2, y: -20)))
        #expect(!fixture.strip.newTabButton.isPressed)
        await fixture.gate.release()
        await task.value
        #expect(fixture.presentations == 0)
        fixture.strip.endNewTabPress(at: fixture.buttonPoint)
        #expect(fixture.intents == [.newTab(after: nil, sameKind: false)])
    }

    @Test(arguments: [false, true])
    func leavingTheWindowCancelsTheHold(detach: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let task = try fixture.press()
        await fixture.gate.waitUntilStarted()
        if detach {
            fixture.strip.removeFromSuperview()
        } else {
            fixture.strip.isHidden = true
        }
        await fixture.gate.release()
        await task.value
        #expect(fixture.presentations == 0)
        #expect(!fixture.strip.pressedNewTab)
        #expect(!fixture.strip.newTabButton.isPressed)
        fixture.strip.endNewTabPress(at: fixture.buttonPoint)
        #expect(fixture.intents.isEmpty)
    }
}

@MainActor private final class Fixture {
    let strip: TabStripView
    let window: NSWindow
    let gate = HoldDelay()
    var presentations = 0
    var intents: [TabStripIntent] = []

    init() {
        let model = TabStripModel(tabs: [TabItem(id: TabID("sample"), title: "Chat")], selectedID: TabID("sample"))
        strip = TabStripView(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = strip
        strip.frame = window.contentLayoutRect
        strip.layoutSubtreeIfNeeded()
        let menu = NSMenu()
        menu.addItem(withTitle: "Terminal", action: nil, keyEquivalent: "")
        strip.contextMenuProvider = { _ in menu }
        strip.presentNewTabMenu = { [weak self] _, _, _ in self?.presentations += 1 }
        model.intentHandler = { [weak self] in self?.intents.append($0) }
        strip.groups.sleep = { [gate] _ in await gate.sleep() }
    }

    var buttonPoint: NSPoint {
        strip.newTabButton.convert(NSPoint(x: strip.newTabButton.bounds.midX, y: strip.newTabButton.bounds.midY), to: strip)
    }

    func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: strip.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func press() throws -> Task<Void, Never> {
        strip.mouseDown(with: try event(.leftMouseDown, at: buttonPoint))
        return try #require(strip.newTabHold.task)
    }

    func close() {
        _ = strip.newTabHold.end()
        window.orderOut(nil)
    }
}

/// Deliberately ignores cancellation until released: the test proves the hold's own
/// cancellation guard rejects a late wake-up, without a wall-clock delay or polling.
private actor HoldDelay {
    private var delay: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var isStarted = false

    func sleep() async {
        await withCheckedContinuation { continuation in
            delay = continuation
            isStarted = true
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        delay?.resume()
        delay = nil
    }
}
