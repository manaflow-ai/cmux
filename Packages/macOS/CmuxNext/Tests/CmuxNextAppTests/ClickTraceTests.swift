import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The release click trace (`cmux app clicks`, #49788). Leo, 2026-11-22: "for some reason i cant click into the
/// composer of the gui chat to focus on it rn". Nothing in a release build said where those clicks went; each press
/// now records the window it reached, what took or forwarded it, and what the page did with its focus grant.
@MainActor struct ClickTraceTests {
    final class Clock {
        var uptime: TimeInterval = 100
    }

    static func press(at point: NSPoint = NSPoint(x: 40, y: 60), timestamp: TimeInterval, window: NSWindow? = nil,
                      type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                                        windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 1,
                                        clickCount: 1, pressure: 1))
    }

    @Test func aPressRecordsItsWindowItsGrantsAndTheKeyWindowAfter() throws {
        _ = NSApplication.shared
        let clock = Clock()
        let trace = ClickTrace(clock: { clock.uptime })
        let page = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.borderless],
                           backing: .buffered, defer: true)
        defer { page.close() }
        let event = try Self.press(timestamp: 5, window: page)
        trace.press(event, window: page)
        trace.press(event, window: page) // the same event again (a window's own sendEvent): no second line
        clock.uptime += 0.2
        trace.pageGrant(tab: "tab_chat", outcome: "kept: first-frame hold")
        trace.dispatched(event, keyWindow: nil)
        let entries = trace.entries()
        try #require(entries.count == 1, "\(entries)")
        let entry = entries[0]
        #expect(entry.window == "NSPanel")
        #expect(entry.windowNumber == page.windowNumber)
        #expect(entry.button == "left")
        #expect(entry.pageGrants == ["tab_chat: kept: first-frame hold"])
        #expect(entry.overlayTook == false)
        #expect(entry.keyWindow == nil)
    }

    /// Nightly 4518008579501 onward trapped in `press` (SIGTRAP, `Int(NaN)`) 3 s after the first window on every
    /// onboarding walk, so a new person's app quit under them. A point that is no number records, never traps.
    @Test func aPressAtAPointThatIsNoNumberRecordsInsteadOfTrapping() throws {
        #expect(ClickTrace.point(.nan) == 0)
        #expect(ClickTrace.point(.infinity) == 0)
        #expect(ClickTrace.point(-.infinity) == 0)
        #expect(ClickTrace.point(CGFloat(Double.greatestFiniteMagnitude)) == Int.max)
        #expect(ClickTrace.point(-CGFloat(Double.greatestFiniteMagnitude)) == Int.min)
        #expect(ClickTrace.point(41.6) == 42)
        _ = NSApplication.shared
        let trace = ClickTrace(clock: { 100 })
        let event = try Self.press(at: NSPoint(x: CGFloat.nan, y: CGFloat.nan), timestamp: 9)
        trace.press(event, window: nil)
        let entries = trace.entries()
        try #require(entries.count == 1, "\(entries)")
        #expect(entries[0].x == 0)
        #expect(entries[0].y == 0)
    }

    @Test func aGrantLongAfterThePressIsNoClicks() throws {
        _ = NSApplication.shared
        let clock = Clock()
        let trace = ClickTrace(clock: { clock.uptime })
        trace.press(try Self.press(timestamp: 1), window: nil)
        clock.uptime += ClickTrace.grantWindow + 0.5
        trace.pageGrant(tab: "tab_later", outcome: "granted")
        #expect(trace.entries().first?.pageGrants == [])
    }

    @Test func theOverlayTakingAPressAndACatcherForwardingOneAreNamed() throws {
        _ = NSApplication.shared
        let trace = ClickTrace()
        let page = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                           backing: .buffered, defer: true)
        let overlay = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        defer { page.close(); overlay.close(); parent.close() }
        // The overlay takes a press the window server gave to a page window (no sendEvent of the app saw it).
        let taken = try Self.press(timestamp: 2, window: page)
        trace.overlayTook(taken, from: page, panel: overlay)
        // A catcher panel over a divider forwards a press to the cmux window (its views, never a page under it).
        let caught = try Self.press(timestamp: 3, window: overlay)
        trace.press(caught, window: overlay)
        trace.forwarded(caught, to: parent)
        // A forward of a press that is not the newest changes nothing.
        trace.forwarded(taken, to: page)
        let entries = trace.entries()
        try #require(entries.count == 2, "\(entries)")
        #expect(entries[0].overlayTook && entries[0].forwardedToNumber == overlay.windowNumber)
        #expect(!entries[1].overlayTook && entries[1].forwardedTo == "NSWindow" && entries[1].forwardedToNumber == parent.windowNumber)
    }

    @Test func theRingKeepsTheNewestPressesInOrder() throws {
        _ = NSApplication.shared
        let trace = ClickTrace()
        let total = ClickTrace.capacity + 25
        for index in 0 ..< total { trace.press(try Self.press(timestamp: Double(index + 1)), window: nil) }
        let entries = trace.entries()
        #expect(entries.count == ClickTrace.capacity)
        #expect(entries.first?.seq == UInt64(total - ClickTrace.capacity + 1))
        #expect(entries.last?.seq == UInt64(total))
        #expect(entries.map(\.seq) == entries.map(\.seq).sorted())
        #expect(trace.entries(limit: 3).map(\.seq) == [UInt64(total - 2), UInt64(total - 1), UInt64(total)])
        // Moves and releases are no presses.
        trace.press(try Self.press(timestamp: 9_999, type: .leftMouseUp), window: nil)
        #expect(trace.entries().last?.seq == UInt64(total))
    }

    /// The method `cmux app clicks` sends is the one the app registers in every build.
    @Test func theCLIReadsTheReleaseMethod() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("cmux-tui/crates/cmux-tui/src/cli/app.rs"), encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.contains("const CLICKS_METHOD: &str = ") })
        let method = try #require(line.split(separator: "\"").dropFirst().first.map(String.init))
        #expect(method == ClickTrace.controlMethod)
    }
}
