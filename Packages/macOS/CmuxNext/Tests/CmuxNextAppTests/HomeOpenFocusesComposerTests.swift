import AppKit
@testable import CmuxNextApp
@testable import CmuxNextHome
import CmuxHomeCore
@testable import MessagesLabSidebar
import Testing

/// Lawrence 2026-10-19 (u2611): "After clicking on one of the things in home (like I click on the
/// profile), I want us to be focused on the text input area directly. Specifically the text input
/// area for sending messages."
///
/// Opening a conversation from Home's list (a click on its row or pinned tile, the one already
/// open too, Return on the highlighted one) leaves the keyboard in that conversation's message
/// box, as Messages does, also when the box only exists once the conversation's first page is in.
/// Up/Down in the list keep the list's keyboard (the person is still moving), and Command- or
/// Shift-click keep the click's old effect (the highlight only).
///
/// The clicks run as AppKit runs them: a left mouse-down on the list's document view at the
/// item's place, with its mouse-up queued for the list's press-and-drag loop.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HomeOpenFocusesComposerTests {
    struct Harness {
        let services: AppServices
        let window: NSWindow
        let page: TopHomePageView

        var document: NSView { page.list.list.controller.document }

        /// The shown conversation's message box, once its first page installed it.
        var box: NSTextView? { page.host?.focusTarget as? NSTextView }

        /// A plain (or modified) click on the list item `id`, mouse-down then mouse-up in place.
        func click(_ id: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let item = try #require(page.list.itemFramesInWindow.first { $0.id.rawValue == id }, "no list item \(id)")
            let height = window.contentView?.bounds.height ?? 0
            let point = NSPoint(x: item.frame.midX, y: height - item.frame.midY)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            Self.post(try event(.leftMouseUp))
            document.mouseDown(with: try event(.leftMouseDown))
            // A list that did not track the press leaves its mouse-up queued: drop it.
            while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
        }

        /// Queues `event` for the list's press-and-drag loop. `NSApp.postEvent` stops the run loop
        /// running when it is called, to wake an event wait; from a test's main-actor job that is
        /// the test process's outermost loop, whose return ends the process. Posted from a pass of
        /// a mode of its own, the stop ends that pass, and the pass runs nothing else. The wake
        /// ends the pass as soon as the event is queued, should AppKit not stop it.
        private static func post(_ event: NSEvent) {
            let mode = CFRunLoopMode("com.cmuxterm.next.tests.post-event" as CFString)
            CFRunLoopPerformBlock(CFRunLoopGetMain(), mode.rawValue) {
                MainActor.assumeIsolated { NSApp.postEvent(event, atStart: false) }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            CFRunLoopRunInMode(mode, 1, true)
        }

        /// A key-down on the list's document view (`keyCode` for arrows, `characters` for Return).
        func key(_ keyCode: UInt16, _ characters: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: keyCode))
            document.keyDown(with: event)
        }

        /// The first responder's class name (never its `description`: AppKit views build it from
        /// their whole state, and some trap when asked during a test).
        var responderName: String { window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing" }

        /// The keyboard is in the shown conversation's message box. A Bool, so a failed
        /// expectation never asks AppKit views for a description (the field's traps).
        var keyboardInBox: Bool { box != nil && window.firstResponder === box }
        var keyboardOnList: Bool { window.firstResponder === document }

        func close() { window.orderOut(nil) }
    }

    static let rows = ["conv_open_focus_a", "conv_open_focus_b", "conv_open_focus_c"]
    static let pinned = "conv_open_focus_pin"

    private static func wait(_ limit: Duration = .seconds(10), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        // Polls a condition the app reaches on its own turns (the first page installing the box).
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Home's two columns in a window: a pinned tile and three rows, `rows[0]` shown with its box in.
    private static func harness() async throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = TopHomePageView(services: services, windowKey: { "open-focus" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        page.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = page
        window.orderFrontRegardless()
        let now = Date()
        let entries = ([pinned] + rows).enumerated().map { index, id in
            CmuxSidebarEntry(id: id, title: id, people: [CmuxSidebarEntry.Person(id: "p\(index)", name: id, initials: "P")],
                             preview: "hi", previewSender: nil, lastAt: now.addingTimeInterval(-Double(index) * 60),
                             unreadCount: 0, pinned: id == pinned)
        }
        // The page's own (empty, offline) inbox model lands on its first turns; the list then shows these items.
        for _ in 0..<50 { await Task.yield() }
        page.list.list.show(entries, pinned: [pinned])
        page.layoutSubtreeIfNeeded()
        page.show(ConversationID(rows[0]))
        let h = Harness(services: services, window: window, page: page)
        await wait { h.box != nil }
        let hasBox = h.box != nil
        try #require(hasBox, "Home's message box never appeared")
        let listed = page.list.itemFramesInWindow.count == entries.count
        try #require(listed, "the list does not show the test items")
        return h
    }

    private static func same(_ a: AnyObject?, _ b: AnyObject?) -> Bool { a != nil && a === b }

    /// The keyboard sat on the list (the person used it last), as before any click on it.
    private static func keyboardOnList(_ h: Harness) {
        h.window.makeFirstResponder(h.document)
    }

    /// A click leaves the run loop it was called from running. In a test process that loop is the
    /// process's outermost one: swift-testing's async main runs `CFRunLoopRun` and exits 0 when it
    /// returns. The harness queued its mouse-up with `NSApp.postEvent`, and AppKit stops the
    /// running loop to wake an event wait (`-[NSEvent _postAtStart:]` calls `CFRunLoopStop`); the
    /// stop stayed on the outermost loop, which returned at the test's next suspension. The whole
    /// CmuxNextAppTests process then ended with exit 0 and no summary, hundreds of tests unfinished
    /// (the PR job's "no Test run with summary line", 2026-10-21). Here the click runs in a nested
    /// pass of the main run loop, which a stop left by the click ends as stopped.
    @Test func aClickLeavesTheRunLoopItRanInRunning() async throws {
        let h = try await Self.harness()
        defer { h.close() }
        var clicked = false
        let result = Self.inANestedPass { clicked = (try? h.click(Self.rows[1])) != nil }
        #expect(clicked, "the click never ran")
        #expect(result == .finished, "the click stopped the run loop it ran in")
    }

    /// Runs `body` in one nested pass of the main run loop and returns how that pass ended:
    /// `.stopped` when `body` stopped it, else `.finished`. The pass runs in a mode of its own, so
    /// it runs `body` and nothing else (a default-mode pass would also run other suites' main-actor
    /// jobs, and end as handled when it drained them), and the wake after `body` ends it.
    private static func inANestedPass(_ body: @escaping () -> Void) -> CFRunLoopRunResult {
        let mode = CFRunLoopMode("com.cmuxterm.next.tests.nested-pass" as CFString)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), mode.rawValue) {
            MainActor.assumeIsolated { body() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return CFRunLoopRunInMode(mode, 5, true)
    }

    /// Every entry point on one Home (a second Home in the same test process does not get its
    /// message box, so the scenarios share one window and run in order).
    @Test func openingAConversationFromTheListPutsTheKeyboardInItsMessageBox() async throws {
        let h = try await Self.harness()
        defer { h.close() }

        // The conversation already open: the click takes the keyboard back to its box.
        guard let first = h.box else { Issue.record("no message box"); return }
        Self.keyboardOnList(h)
        try h.click(Self.rows[0])
        let ok1 = h.page.shown?.rawValue == Self.rows[0]
        #expect(ok1)
        let ok2 = Self.same(h.page.host?.focusTarget, first)
        #expect(ok2, "reopening the shown conversation made a new transcript")
        let ok3 = Self.same(h.window.firstResponder, first)
        #expect(ok3, "a click on the open conversation left the keyboard on \(h.responderName)")

        // A conversation row (a thread or a profile's DM).
        Self.keyboardOnList(h)
        try h.click(Self.rows[1])
        let ok4 = h.page.shown?.rawValue == Self.rows[1]
        #expect(ok4)
        await Self.wait { h.keyboardInBox }
        let ok5 = h.keyboardInBox
        #expect(ok5, "a row click left the keyboard on \(h.responderName)")

        // A pinned contact's tile.
        Self.keyboardOnList(h)
        try h.click(Self.pinned)
        let ok6 = h.page.shown?.rawValue == Self.pinned
        #expect(ok6)
        await Self.wait { h.keyboardInBox }
        let ok7 = h.keyboardInBox
        #expect(ok7, "a pinned tile click left the keyboard on \(h.responderName)")

        // Command- and Shift-clicks keep the keyboard where it was.
        for modifier in [NSEvent.ModifierFlags.command, .shift] {
            Self.keyboardOnList(h)
            try h.click(Self.rows[2], modifiers: modifier)
            let ok8 = h.keyboardOnList
            #expect(ok8, "a \(modifier) click moved the keyboard to \(h.responderName)")
        }

        // Down in the list only moves the selection; Return opens it in its box.
        try h.click(Self.rows[0], modifiers: .command)
        Self.keyboardOnList(h)
        try h.key(125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        let ok9 = h.page.shown?.rawValue == Self.rows[1]
        #expect(ok9, "Down did not move to the next conversation")
        let ok10 = h.keyboardOnList
        #expect(ok10, "Down moved the keyboard out of the list")
        try h.key(36, "\r")
        await Self.wait { h.keyboardInBox }
        let ok11 = h.keyboardInBox
        #expect(ok11, "Return left the keyboard on \(h.responderName)")
    }
}
