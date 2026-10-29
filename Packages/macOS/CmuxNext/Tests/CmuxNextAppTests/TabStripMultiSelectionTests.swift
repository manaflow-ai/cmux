import AppKit
@testable import CmuxNextInput
@testable import CmuxNextTabs
import Testing

/// The strip's Escape exits through the app's input tap: a multi-selection holds an
/// Escape intercept on the strip's window only while it lasts and lets the key go on; a drag holds one
/// that cancels the drag and stops the key; both leave the tap when their mode ends or the strip
/// leaves its window, and another window's Escape is not theirs.
@MainActor @Suite(.serialized) struct TabStripMultiSelectionTests {
    @MainActor final class Harness {
        let tap = InputEventTap()
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)

        init() {
            model = TabStripModel(tabs: (0..<6).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t1"))
            strip = TabStripView(model: model, input: tap)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            window.isReleasedWhenClosed = false
            window.contentView = strip
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in
                if case .select(let id) = intent { model.selectedID = id }
            }
        }

        /// A point inside tab `id`, in window coordinates.
        func point(_ id: String) throws -> CGPoint {
            let cell = try #require(strip.cells[TabID(id)], "no cell for \(id)")
            return strip.convert(strip.convert(CGPoint(x: cell.frame.minX + 12, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        }

        func mouse(_ type: NSEvent.EventType, at point: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        func click(_ id: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
            let at = try point(id)
            strip.mouseDown(with: try mouse(.leftMouseDown, at: at, modifiers))
            strip.mouseUp(with: try mouse(.leftMouseUp, at: at, modifiers))
            strip.syncFromModel()
        }

        /// Sends Escape through the tap as CmuxApplication does; returns what the intercepts did.
        func escape(in target: NSWindow? = nil) throws -> InputEventTap.InterceptResult {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: (target ?? window).windowNumber, context: nil, characters: "\u{1b}",
                                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            var result = InputEventTap.InterceptResult.pass
            tap.dispatching {
                tap.deliverObserve(event)
                result = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
            return result
        }

        var keyIntercepts: Int { tap.subscriberCount(.key, stage: .intercept) }
    }

    @Test func aMultiSelectionHoldsTheEscapeInterceptOnlyWhileItLasts() throws {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        #expect(harness.keyIntercepts == 0, "a strip with one selected tab costs the tap nothing")
        try harness.click("t3", .command)
        #expect(harness.model.multiSelection.isMultiple)
        #expect(harness.strip.selectionEscape.isInstalled)
        #expect(harness.keyIntercepts == 1)

        #expect(try harness.escape() == .pass, "Escape goes on to whatever has focus")
        #expect(!harness.model.multiSelection.isMultiple, "Escape ends the multi-selection")
        harness.strip.syncFromModel()
        #expect(!harness.strip.selectionEscape.isInstalled)
        #expect(harness.keyIntercepts == 0, "the intercept leaves the tap with the selection")
    }

    @Test func anotherWindowsEscapeKeepsTheSelection() throws {
        let harness = Harness()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFrontRegardless()
        defer { for window in [harness.window, other] { window.orderOut(nil) } }
        try harness.click("t3", .command)

        #expect(try harness.escape(in: other) == .pass)
        #expect(harness.model.multiSelection.isMultiple, "the intercept is scoped to the strip's window")
    }

    @Test func escapeDuringADragCancelsItStopsTheKeyAndKeepsTheSelection() throws {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        try harness.click("t3", .command)
        let start = try harness.point("t1")
        harness.strip.mouseDown(with: try harness.mouse(.leftMouseDown, at: start))
        harness.strip.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: CGPoint(x: start.x + 300, y: start.y)))
        #expect(harness.strip.drag != nil, "the drag began")
        #expect(harness.strip.escapeMonitor.isInstalled)
        #expect(harness.keyIntercepts == 2, "the drag's intercept joins the selection's")

        #expect(try harness.escape() == .consume, "the drag's Escape stops at the strip")
        #expect(harness.strip.drag == nil, "Escape cancels the drag")
        #expect(!harness.strip.escapeMonitor.isInstalled)
        #expect(harness.model.multiSelection.isMultiple, "the drag's Escape runs first and ends only the drag")
        #expect(harness.keyIntercepts == 1, "only the selection's intercept is left")
    }

    @Test func theStripLeavingItsWindowDropsItsIntercepts() throws {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        try harness.click("t3", .command)
        #expect(harness.keyIntercepts == 1)

        harness.window.contentView = nil
        #expect(!harness.strip.selectionEscape.isInstalled)
        #expect(harness.keyIntercepts == 0, "a strip out of sight holds nothing in the tap")
    }

    @Test func aStripWithNoWindowInstallsNothing() throws {
        let tap = InputEventTap()
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t0"))
        let strip = TabStripView(model: model, input: tap)
        strip.selectionEscape.install()
        strip.escapeMonitor.install()
        #expect(!strip.selectionEscape.isInstalled)
        #expect(!strip.escapeMonitor.isInstalled)
        #expect(tap.subscriberCount(.key, stage: .intercept) == 0)
    }
}
