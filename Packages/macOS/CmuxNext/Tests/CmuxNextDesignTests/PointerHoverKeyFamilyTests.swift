import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// 2026-11-13, the workspace switch between two workspaces that each show a Chromium page: the key
/// window moves twice (the page that left gives it to the cmux window; the page that shows takes it
/// after its first frame), and each move posts a resign and a become. `PointerHover` recomputed, at
/// each of the 4 notices, every target that hovers and every target under the pointer, and each
/// such target asks the window server which window is topmost at the pointer
/// (`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`, a synchronous round trip). A sample of
/// 10 such switches by a debug action had 39 of its main-thread samples there.
///
/// A key change between a window and its own page window changes no window order: the page
/// window is the pane's content, above its window before and after. So it asks nothing. A key
/// change to another window can come with a new window order (the other window covers the
/// pointer), so it still recomputes the hover, and so does a window that resigns key to no window
/// (another app), a panel of the window that takes the key, and a page window of no window.
///
/// The tests use a synthesized pointer, with which `PointerHover.isTopmost` returns before its
/// window server read. They count the asks one step before it: `passThroughWindows` is read
/// exactly when a target reaches its topmost check, once for each window server ask of the app.
@MainActor @Suite(.serialized, .closesItsWindows) struct PointerHoverKeyFamilyTests {
    private static func makeWindow(_ type: NSWindow.Type = NSWindow.self) -> NSWindow {
        let window = type.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                               backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// `CefNSWindow`, the class of a Chromium page window: the app has it from the Chromium
    /// framework, a test process makes a stand-in of the same name.
    private static func pageWindowClass() throws -> NSWindow.Type {
        if let existing = objc_lookUpClass("CefNSWindow") { return try #require(existing as? NSWindow.Type) }
        let made: AnyClass = try #require(objc_allocateClassPair(NSWindow.self, "CefNSWindow", 0))
        objc_registerClassPair(made)
        return try #require(made as? NSWindow.Type)
    }

    /// The key window moves from `old` to `new`, as AppKit posts it: the resign, then the become.
    private static func key(leaves old: NSWindow?, goesTo new: NSWindow?) {
        // global-notice-allow: PointerHover's one key observer reads the default center and takes no center; posted on the main thread, the object is this suite's own window
        if let old { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: old) }
        // global-notice-allow: the become of the same key change, in the same call as its resign (see above)
        if let new { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: new) }
    }

    /// The rest of this turn of the main run loop (a key change that ends with no key window is
    /// settled there).
    private static func endTurn() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private static func close(_ windows: NSWindow...) {
        for window in windows {
            PointerHover.debugPointers[ObjectIdentifier(window)] = nil
            window.parent?.removeChildWindow(window)
            window.close()
        }
    }

    /// A window, a child window of `childType` above it, and `count` plain targets under the
    /// window's synthesized pointer (all hover).
    private static func rig(child childType: NSWindow.Type, targets count: Int = 3) throws -> (window: NSWindow, child: NSWindow, hovers: [PointerHover]) {
        let window = makeWindow(), child = makeWindow(childType)
        window.addChildWindow(child, ordered: .above)
        let content = try #require(window.contentView)
        var hovers: [PointerHover] = []
        for _ in 0..<count {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            content.addSubview(view)
            hovers.append(PointerHover(view))
        }
        PointerHover.setDebugPointer(NSPoint(x: 50, y: 20), in: window)
        #expect(hovers.allSatisfy { $0.isHovering })
        // The window holds the key.
        key(leaves: nil, goesTo: window)
        return (window, child, hovers)
    }

    @Test func aKeyChangeBetweenAWindowAndItsPageWindowAsksNoTopmostWindow() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass())
        defer { Self.close(page, window) }
        var asks = 0
        for hover in hovers {
            hover.passThroughWindows = {
                asks += 1
                return []
            }
        }

        // The page takes the key (its first frame after a switch, a click in it).
        Self.key(leaves: window, goesTo: page)
        #expect(asks == 0, "the key going to the window's own page asked the topmost window \(asks) times for 3 targets")
        #expect(hovers.allSatisfy { $0.isHovering })

        // The page gives it back (the page leaves at a switch, a click in the sidebar).
        asks = 0
        Self.key(leaves: page, goesTo: window)
        #expect(asks == 0, "the key coming back from the window's own page asked the topmost window \(asks) times for 3 targets")
        #expect(hovers.allSatisfy { $0.isHovering })
    }

    /// A target that needs the key window depends on the key itself: it is recomputed at each
    /// key change of its window, also one inside the family.
    @Test func aKeyWindowTargetIsStillRecomputedAtAKeyChangeInsideTheFamily() throws {
        let (window, page, _) = try Self.rig(child: Self.pageWindowClass(), targets: 0)
        defer { Self.close(page, window) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        try #require(window.contentView).addSubview(view)
        let hover = PointerHover(view, requiresKeyWindow: true)
        var asked = 0
        hover.isHoverable = {
            asked += 1
            return true
        }
        PointerHover.refresh(in: window)
        #expect(hover.isHovering)

        asked = 0
        Self.key(leaves: window, goesTo: page)
        #expect(asked > 0, "a key-window target was not recomputed when its window lost the key to its page")
        asked = 0
        Self.key(leaves: page, goesTo: window)
        #expect(asked > 0, "a key-window target was not recomputed when its window got the key back from its page")
    }

    /// The pointer is over a target, the key goes to a second window and comes back. The second
    /// window can cover the pointer, so each of the two changes recomputes the hover. A synthesized
    /// pointer has no topmost window to lose, so the test makes the target's answer stale another
    /// way (`isHoverable` changes with no refresh) and reads that the key change saw it.
    @Test func aKeyChangeToAnotherWindowAndBackRecomputesTheHover() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass(), targets: 1)
        let other = Self.makeWindow()
        defer { Self.close(page, window, other) }
        let hover = try #require(hovers.first)
        var hoverable = true
        hover.isHoverable = { hoverable }

        hoverable = false
        Self.key(leaves: window, goesTo: other)
        #expect(!hover.isHovering, "the key going to another window did not recompute the hover")

        hoverable = true
        Self.key(leaves: other, goesTo: window)
        #expect(hover.isHovering, "the key coming back from another window did not recompute the hover")

        // The same from the page: the key is in the window's page when it leaves.
        Self.key(leaves: window, goesTo: page)
        hoverable = false
        Self.key(leaves: page, goesTo: other)
        #expect(!hover.isHovering, "the key going from the page to another window did not recompute the hover")
    }

    /// A page that leaves at a workspace switch can resign the key after it left its parent, and
    /// the one that shows can take it again before it is a child again: it is still the page of
    /// the window that a key change last saw it in.
    @Test func aPageThatLeftItsParentStillBelongsToItsWindow() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass())
        defer { Self.close(page, window) }
        Self.key(leaves: window, goesTo: page)
        var asks = 0
        for hover in hovers {
            hover.passThroughWindows = {
                asks += 1
                return []
            }
        }

        window.removeChildWindow(page)
        Self.key(leaves: page, goesTo: window)
        #expect(asks == 0, "the key coming back from a page that left its parent asked the topmost window \(asks) times")
        Self.key(leaves: window, goesTo: page)
        #expect(asks == 0, "the key going to a page that is not a child again yet asked the topmost window \(asks) times")
        #expect(hovers.allSatisfy { $0.isHovering })
    }

    /// A page window that no key change saw as a child of a window belongs to none: it can be a
    /// window of its own over the pointer, so the hover is recomputed.
    @Test func aPageWindowThatWasNeverAChildRecomputesTheHover() throws {
        let window = Self.makeWindow(), page = Self.makeWindow(try Self.pageWindowClass())
        defer { Self.close(page, window) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        try #require(window.contentView).addSubview(view)
        let hover = PointerHover(view)
        var hoverable = true
        hover.isHoverable = { hoverable }
        PointerHover.setDebugPointer(NSPoint(x: 50, y: 20), in: window)
        #expect(hover.isHovering)
        Self.key(leaves: nil, goesTo: window)

        hoverable = false
        Self.key(leaves: window, goesTo: page)
        #expect(!hover.isHovering, "a page window of no window took the key and the hover was not recomputed")
    }

    /// A child window that is no page (a panel, a popover, a sheet's window) can show over the
    /// pointer when it takes the key: it is not the family's page, and the hover is recomputed.
    @Test func aChildWindowThatIsNoPageRecomputesTheHoverWhenItTakesTheKey() throws {
        let (window, panel, hovers) = try Self.rig(child: NSWindow.self, targets: 1)
        defer { Self.close(panel, window) }
        let hover = try #require(hovers.first)
        var hoverable = true
        hover.isHoverable = { hoverable }

        hoverable = false
        Self.key(leaves: window, goesTo: panel)
        #expect(!hover.isHovering, "a panel of the window took the key and the hover was not recomputed")
        hoverable = true
        Self.key(leaves: panel, goesTo: window)
        #expect(hover.isHovering, "the key came back from a panel of the window and the hover was not recomputed")
    }

    /// The key leaves and no window of the app takes it (another app comes to the front, and its
    /// window can cover the pointer): the hover is recomputed in that turn of the run loop.
    @Test func aWindowThatResignsKeyToNoWindowRecomputesItsHoverInThatTurn() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass(), targets: 1)
        defer { Self.close(page, window) }
        let hover = try #require(hovers.first)
        var hoverable = true
        hover.isHoverable = { hoverable }

        hoverable = false
        Self.key(leaves: window, goesTo: nil)
        Self.endTurn()
        #expect(!hover.isHovering, "the window resigned key to no window and the hover was not recomputed")

        // The app comes back: the window becomes key with no resign before it.
        hoverable = true
        Self.key(leaves: nil, goesTo: window)
        #expect(hover.isHovering, "the window became key again and the hover was not recomputed")

        // The same when the page held the key.
        Self.key(leaves: window, goesTo: page)
        hoverable = false
        Self.key(leaves: page, goesTo: nil)
        Self.endTurn()
        #expect(!hover.isHovering, "the page resigned key to no window and the hover was not recomputed")
    }
}
