import AppKit
@testable import CmuxNextDesign
import CmuxNextCompat
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// 2026-11-13, the workspace switch between two workspaces that each show a Chromium page: the key
/// window moves twice (the page that left gives it to the cmux window; the page that shows takes it
/// after its first frame), and each move posts a resign and a become. `PointerHover` recomputed, at
/// each of the 4 notices, every target that hovers and every target under the pointer, and each
/// such target asks the window server which window is topmost at the pointer
/// (`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`, a synchronous round trip). A sample of
/// 20 such switches by a debug action had 39 of its main-thread samples there.
///
/// A key change between a window and its own page window recomputes nothing at its notices. The
/// window is recomputed one time when that pass of the run loop ends, for all such notices of the
/// pass: the page that leaves is ordered out with its key change, which uncovers what it covered
/// under a still pointer, and the switch hid and showed views that do not all report it. A key
/// change to another window can come with a new window order (the other window covers the
/// pointer), so it still recomputes the hover at once, and so does a window that resigns key to no
/// window (another app), a panel of the window that takes the key, and a page window whose window
/// is not known. A page window with no parent (ordered out as it leaves) is the page of the window
/// that a key change last saw it in; nothing is guessed for a page that no key change saw with a
/// parent.
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

    /// The count. The 4 key notices of a page that takes the key and gives it back ask nothing
    /// when they post, and the window is recomputed one time when their pass ends: one ask for
    /// each of the 3 targets under the pointer, where each notice asked 3 times before.
    @Test func theKeyNoticesOfOnePassBetweenAWindowAndItsPageRecomputeItOnceWhenThePassEnds() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass())
        defer { Self.close(page, window) }
        let first = try #require(hovers.first)
        let asks = Asks(hovers)

        // The page takes the key (its first frame after a switch, a click in it).
        Self.key(leaves: window, goesTo: page)
        #expect(asks.count == 0, "the key going to the window's own page asked the topmost window \(asks.count) times for 3 targets when it posted")
        // The page gives it back (the page leaves at a switch, a click in the sidebar).
        Self.key(leaves: page, goesTo: window)
        #expect(asks.count == 0, "the key coming back from the window's own page asked the topmost window \(asks.count) times for 3 targets when it posted")
        #expect(hovers.allSatisfy { $0.isHovering })

        let pass = Self.endPass(asks, first)
        #expect(pass.asks == 3, "the pass of 4 key notices inside one window asked the topmost window \(pass.asks ?? -1) times for 3 targets; one recompute is 3")
        #expect(pass.hoveringAtEnd == true)
    }

    /// The visible side of a workspace switch between two browser tabs, under a pointer that does
    /// not move, in the order the app has: the window hides the old workspace's content and shows
    /// the new one (plain views here, which report no hide and no unhide, as some controls of the
    /// app); the old page is ordered out and gives the key to its window; in a later pass the new
    /// page takes the key. When each of the two passes ends, where its frame is committed, the
    /// control of the old content is not hovered and the control at its place in the new content is.
    @Test func afterASwitchTheHoverIsThatOfTheNewContentWhenEachPassEnds() throws {
        let pageClass = try Self.pageWindowClass()
        let window = Self.makeWindow(), oldPage = Self.makeWindow(pageClass), newPage = Self.makeWindow(pageClass)
        defer { Self.close(oldPage, newPage, window) }
        window.addChildWindow(oldPage, ordered: .above)
        let content = try #require(window.contentView)
        let oldContent = NSView(frame: content.bounds), newContent = NSView(frame: content.bounds)
        let oldControl = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        let newControl = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        oldContent.addSubview(oldControl)
        newContent.addSubview(newControl)
        newContent.isHidden = true
        content.addSubview(oldContent)
        content.addSubview(newContent)
        let oldHover = PointerHover(oldControl), newHover = PointerHover(newControl)
        PointerHover.setDebugPointer(NSPoint(x: 50, y: 20), in: window)
        // The old page holds the key, and its pass ended.
        Self.key(leaves: nil, goesTo: window)
        Self.key(leaves: window, goesTo: oldPage)
        #expect(Self.hoveringWhenThePassEnds([oldHover, newHover]) == [true, false])

        // The switch: the content changes, then the old page leaves.
        oldContent.isHidden = true
        newContent.isHidden = false
        window.removeChildWindow(oldPage)
        Self.key(leaves: oldPage, goesTo: window)
        let afterTheOldPageLeft = Self.hoveringWhenThePassEnds([oldHover, newHover])
        #expect(afterTheOldPageLeft == [false, true], "when the pass of the switch ended, the hover of the old content's control and of the new one was \(String(describing: afterTheOldPageLeft)), not [false, true]")

        // The new page shows and takes the key, in a later pass.
        window.addChildWindow(newPage, ordered: .above)
        Self.key(leaves: window, goesTo: newPage)
        let afterTheNewPageShowed = Self.hoveringWhenThePassEnds([oldHover, newHover])
        #expect(afterTheNewPageShowed == [false, true], "when the pass of the new page's key ended, the hover of the old content's control and of the new one was \(String(describing: afterTheNewPageShowed)), not [false, true]")
    }

    /// The same from a page to a terminal: the page window covered the pointer, and its leaving
    /// uncovers a control of the window under it. Nothing reports that to the control but the key
    /// change: when the pass ends, the control is recomputed.
    @Test func aPageThatLeavesRecomputesWhatItCoveredWhenThePassEnds() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass(), targets: 1)
        defer { Self.close(page, window) }
        let hover = try #require(hovers.first)
        var hoverable = false
        hover.isHoverable = { hoverable }
        // The page holds the key and covers the control: it does not hover.
        Self.key(leaves: window, goesTo: page)
        hover.refresh()
        #expect(Self.hoveringWhenThePassEnds([hover]) == [false])

        // The page leaves (here the control's own answer changes, as the topmost window does in the app).
        hoverable = true
        window.removeChildWindow(page)
        Self.key(leaves: page, goesTo: window)
        #expect(Self.hoveringWhenThePassEnds([hover]) == [true], "a page left and gave the key to its window, and what it covered was not recomputed when the pass ended")
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

    /// The targets' asks of the topmost window from now on (one for each target at each recompute).
    @MainActor private final class Asks {
        var count = 0
        init(_ hovers: [PointerHover]) {
            for hover in hovers {
                hover.passThroughWindows = { [self] in
                    count += 1
                    return []
                }
            }
        }
    }

    /// What one pass of the main run loop gave.
    @MainActor private final class Pass {
        /// The asks when the blocks that the pass had queued had run, before its other work.
        var asks: Int?
        /// The target's hover when the run loop first went to wait: the end of the pass, where
        /// its frame is committed.
        var hoveringAtEnd: Bool?
    }

    /// Runs the pass of the main run loop that a key notice of this call is in, and reads it.
    /// The count is read in a block of the run loop queued after the observer's own (they run in
    /// order, before the pass does other work, so another suite's refresh is not counted).
    private static func endPass(_ asks: Asks, _ hover: PointerHover) -> Pass {
        let pass = Pass()
        MainRunLoopBlock.perform { pass.asks = asks.count }
        let end = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: CFIndex.min) { _ in
            if pass.hoveringAtEnd == nil { pass.hoveringAtEnd = hover.isHovering }
        }
        endTurn()
        end.invalidate()
        return pass
    }

    /// What the hover of each of `hovers` was at the end of one pass (`hoveringWhenThePassEnds`).
    @MainActor private final class PassEnd {
        var hovering: [Bool]?
    }

    /// Runs the pass of the main run loop that a key notice of this call is in, and gives the
    /// hover of each of `hovers` when the run loop first went to wait: the end of the pass, where
    /// its frame is committed.
    private static func hoveringWhenThePassEnds(_ hovers: [PointerHover]) -> [Bool]? {
        let passEnd = PassEnd()
        let end = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: CFIndex.min) { _ in
            if passEnd.hovering == nil { passEnd.hovering = hovers.map { $0.isHovering } }
        }
        endTurn()
        end.invalidate()
        return passEnd.hovering
    }

    /// A page that leaves at a workspace switch is ordered out, which takes it from its parent: it
    /// is still the page of the window that the last key change saw it in.
    @Test func aPageThatLeftItsParentStillBelongsToItsWindow() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass())
        defer { Self.close(page, window) }
        let first = try #require(hovers.first)
        // The page takes the key as a child of its window.
        Self.key(leaves: window, goesTo: page)
        let asks = Asks(hovers)

        window.removeChildWindow(page)
        Self.key(leaves: page, goesTo: window)
        #expect(asks.count == 0, "the key coming back from a page that left its parent asked the topmost window \(asks.count) times when it posted")
        Self.key(leaves: window, goesTo: page)
        #expect(asks.count == 0, "the key going to the window's page that has no parent now asked the topmost window \(asks.count) times when it posted")
        #expect(hovers.allSatisfy { $0.isHovering })
        // One recompute of the window for the whole pass: one ask for each of its 3 targets.
        let pass = Self.endPass(asks, first)
        #expect(pass.asks == 3, "the pass of the key changes of a page with no parent asked the topmost window \(pass.asks ?? -1) times for 3 targets")
    }

    /// Nothing is guessed: a page window that no key change saw with a parent is no window's
    /// page. It can be a window of its own over the pointer, so the hover is recomputed.
    @Test func aPageWindowThatNoKeyChangeSawWithAParentRecomputesTheHover() throws {
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
        let observer = try #require(PointerHover.keyObserver)
        #expect(observer.knownHome(of: page) == nil)

        hoverable = false
        Self.key(leaves: window, goesTo: page)
        #expect(!hover.isHovering, "a page window of no known window took the key and the hover was not recomputed")
        hoverable = true
        Self.key(leaves: page, goesTo: window)
        #expect(hover.isHovering, "a page window of no known window gave the key back and the hover was not recomputed")
    }

    /// What the observer knows of a page lasts only as long as the page and its window: a page
    /// window that closes leaves it, and a window that closes takes its pages with it.
    @Test func aClosedPageWindowLeavesWhatTheObserverKnows() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass())
        let second = Self.makeWindow(try Self.pageWindowClass())
        defer { Self.close(second, page, window) }
        let observer = try #require(PointerHover.keyObserver)
        window.addChildWindow(second, ordered: .above)
        Self.key(leaves: window, goesTo: page)
        Self.key(leaves: page, goesTo: second)
        #expect(observer.knownHome(of: page) === window)
        #expect(observer.knownHome(of: second) === window)

        window.removeChildWindow(page)
        #expect(observer.knownHome(of: page) === window, "a page that only left its parent is still known")
        page.close()
        #expect(observer.knownHome(of: page) == nil, "a closed page window was still known")
        // Not known any more: a key notice from it is read as one of a window of its own.
        let asks = Asks(hovers)
        Self.key(leaves: page, goesTo: window)
        #expect(asks.count > 0, "the key coming from a closed page window did not recompute the hover")

        // The window closes: its other page is not known as its page any more.
        window.removeChildWindow(second)
        window.close()
        #expect(observer.knownHome(of: second) == nil, "a page of a closed window was still known as its page")
    }

    /// A page moves to a second window (a tab dragged to another window). It is that window's
    /// page from the first key change that sees it there: a key change between it and its old
    /// window is a change to another window, the full recompute.
    @Test func aPageThatMovedToASecondWindowIsThatWindowsPage() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass())
        let second = Self.makeWindow()
        defer { Self.close(page, window, second) }
        let observer = try #require(PointerHover.keyObserver)
        Self.key(leaves: window, goesTo: page)
        #expect(observer.knownHome(of: page) === window)
        // That change's pass ends (its one recompute of the first window is not counted below).
        Self.endTurn()

        window.removeChildWindow(page)
        second.addChildWindow(page, ordered: .above)
        let asks = Asks(hovers)
        Self.key(leaves: page, goesTo: window)
        #expect(asks.count > 0, "the key going from the second window's page to the first window did not recompute the hover")
        #expect(observer.knownHome(of: page) === second, "the page's window was not replaced when a key change saw it in the second window")

        asks.count = 0
        Self.key(leaves: window, goesTo: second)
        #expect(asks.count > 0, "the key going between the two windows did not recompute the hover")

        // Inside the second window now, also after the page leaves its parent there.
        asks.count = 0
        Self.key(leaves: second, goesTo: page)
        second.removeChildWindow(page)
        Self.key(leaves: page, goesTo: second)
        #expect(asks.count == 0, "a key change between the second window and its page asked the topmost window \(asks.count) times when it posted")
        asks.count = 0
        Self.key(leaves: second, goesTo: window)
        #expect(asks.count > 0, "the key coming back to the first window did not recompute the hover")
    }

    /// The person goes to another app: the window resigns key and no window becomes key. The
    /// hover is recomputed exactly once, and in that pass of the run loop: before the run loop
    /// first goes to wait, which is where the pass's frame is committed.
    @Test func aResignWithNoBecomeIsRecomputedOnceBeforeThePassEnds() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass(), targets: 1)
        defer { Self.close(page, window) }
        let hover = try #require(hovers.first)
        var hoverable = true
        hover.isHoverable = { hoverable }
        let asks = Asks(hovers)

        // The hover ends in the pass of the resign.
        hoverable = false
        Self.key(leaves: window, goesTo: nil)
        #expect(Self.endPass(asks, hover).hoveringAtEnd == false, "the hover was still there when the pass of the resign ended")

        // Exactly once: a target that hovers asks once for each recompute.
        hoverable = true
        Self.key(leaves: nil, goesTo: window)
        #expect(hover.isHovering)
        asks.count = 0
        Self.key(leaves: window, goesTo: nil)
        let pass = Self.endPass(asks, hover)
        #expect(pass.asks == 1, "a resign with no become recomputed the hover \(pass.asks ?? -1) times in its pass")
        #expect(pass.hoveringAtEnd == true)

        // The same when the page held the key and its window is the one under the pointer.
        Self.key(leaves: nil, goesTo: page)
        asks.count = 0
        Self.key(leaves: page, goesTo: nil)
        #expect(Self.endPass(asks, hover).asks == 1, "a page's resign with no become did not recompute the hover once in its pass")
    }

    /// The resign and the become of one key change in two passes of the run loop (another app
    /// held the key between them, or AppKit split them): no recompute is missed, and the cost is
    /// what it was before, one recompute for each of the two notices.
    @Test func aResignAndItsBecomeInTwoPassesMissNoRecompute() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass(), targets: 1)
        defer { Self.close(page, window) }
        let hover = try #require(hovers.first)
        var hoverable = true
        hover.isHoverable = { hoverable }
        let asks = Asks(hovers)

        Self.key(leaves: window, goesTo: nil)
        let resignPass = Self.endPass(asks, hover).asks
        #expect(resignPass == 1, "the pass of the resign recomputed the hover \(resignPass ?? -1) times")
        // The become of the window's own page comes in a later pass. What the pointer is over
        // changed between the two (here: the target stopped being hoverable), so the become is
        // the full recompute and not a change inside the window.
        hoverable = false
        Self.key(leaves: nil, goesTo: page)
        #expect(!hover.isHovering, "a become in a later pass than its resign did not recompute the hover")

        // The other way, and the cost: at most one recompute for each of the two notices.
        hoverable = true
        Self.key(leaves: nil, goesTo: window)
        #expect(hover.isHovering)
        asks.count = 0
        Self.key(leaves: window, goesTo: nil)
        let first = Self.endPass(asks, hover).asks ?? 0
        asks.count = 0
        Self.key(leaves: nil, goesTo: page)
        #expect(hover.isHovering)
        #expect(first + asks.count == 2, "a key change over two passes asked the topmost window \(first + asks.count) times; it was 2 before")
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

    /// Posts the two key notices of its window as it leaves it inside that window's deallocation:
    /// a window that deallocates tears its views down, and a view there still reports the dying
    /// window as its window (`PointerHoverWindowDeallocTests`).
    private final class KeyNoticeAtTeardownView: NSView {
        /// The notices went out, for a window that was in deallocation.
        private(set) var postedInDeallocation = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard newWindow == nil, let dying = window, dying.isBeingDeallocated else { return }
            PointerHoverKeyFamilyTests.key(leaves: dying, goesTo: dying)
            postedInDeallocation = true
        }
    }

    /// A key notice whose window is in deallocation. The observer keeps weak references to the
    /// window of a key notice, and the runtime aborts on a weak reference to an object in
    /// deallocation ("Cannot form weak reference to instance ... of class NSWindow"). Such a
    /// window is no window for the observer: its resign and its become do nothing, and the resign
    /// of another window before them, in the same pass, is still a resign with no become: that
    /// window is recomputed one time when the pass ends.
    @Test func aKeyNoticeOfAWindowInDeallocationIsNoKeyChange() throws {
        let (window, page, hovers) = try Self.rig(child: Self.pageWindowClass(), targets: 1)
        defer { Self.close(page, window) }
        let hover = try #require(hovers.first)
        let asks = Asks(hovers)
        let view = KeyNoticeAtTeardownView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))

        // The window resigns key: where the key goes is not known yet.
        Self.key(leaves: window, goesTo: nil)
        weak var released: NSWindow?
        autoreleasepool {
            let dying = Self.makeWindow()
            dying.contentView?.addSubview(view)
            released = dying
        }
        #expect(released == nil, "the window deallocated")
        #expect(view.postedInDeallocation, "no key notice went out for a window in deallocation: the test proves nothing")
        #expect(asks.count == 0, "a key notice of a window in deallocation asked the topmost window \(asks.count) times when it posted")

        let pass = Self.endPass(asks, hover)
        #expect(pass.asks == 1, "the resign before a key notice of a window in deallocation recomputed the hover \(pass.asks ?? -1) times in its pass; one recompute is 1")
        #expect(pass.hoveringAtEnd == true)
    }
}
