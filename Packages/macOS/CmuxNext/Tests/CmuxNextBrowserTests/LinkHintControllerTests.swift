import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import ObjectiveC
import Testing

/// Review of #32537 (6591620612 finding 3, 6594559342): the link-hint controller itself, with the page's answers and the
/// send-back path stood in for: every key typed while the page answers reaches the page once, in order, or is a hint
/// key; the answer's bound never sends hint letters to a page with no text field; a key Chromium sends back is the
/// page's even when Chromium loaded after the first key.
@MainActor @Suite(.serialized, .closesItsWindows) struct LinkHintControllerTests {
    /// An answer the test gives when it chooses.
    @MainActor private final class Answer<Value: Sendable> {
        private var waiter: CheckedContinuation<Value?, Never>?
        var isAsked: Bool { waiter != nil }
        nonisolated deinit {}
        func next() async -> Value? { await withCheckedContinuation { waiter = $0 } }
        func give(_ value: Value?) {
            let waiter = self.waiter
            self.waiter = nil
            waiter?.resume(returning: value)
        }
    }

    /// A controller on a tab whose page answers through `focus` and `targets`, and the keys it gave the page.
    @MainActor private final class Harness {
        let controller = LinkHintController()
        let focus = Answer<Bool>()
        let targets = Answer<[LinkHintTarget]>()
        let shell = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let tab: CEFTab
        var sent: [String] = []
        var noLinks = 0

        init() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "link-hints-\(UUID().uuidString)", directoryHint: .isDirectory)
            let runtime = CEFRuntime(shim: try Self.library(), storage: CEFProfileStorage(root: root))
            Self.runtimes.append(runtime)
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            controller.focusAnswer = { [focus] _ in await focus.next() }
            controller.targetsAnswer = { [targets] _ in await targets.next() }
            controller.send = { [weak self] keys in self?.sent += keys.map(Self.describe) }
        }

        func start() async {
            controller.start(.follow, tab: tab, window: shell, isFocused: { true }, openInSplit: { _ in }, noLinks: { [weak self] in self?.noLinks += 1 })
            await until { focus.isAsked }
        }

        /// Types `text` while the session runs: each key-down through the intercept, its key-up before AppKit.
        func type(_ text: [String], in window: NSWindow? = nil) {
            for (index, key) in text.enumerated() {
                let code = Self.code(key, index)
                let down = Self.key(key, .keyDown, code: code, window: window ?? shell)
                controller.noteKeyDown(down, in: window ?? shell)
                if !controller.interceptKeyDown(down, in: window ?? shell) { sent.append(Self.describe(down) + "(passed)") }
                if !controller.inputWillDispatch(Self.key(key, .keyUp, code: code, window: window ?? shell)) { sent.append("^\(key)(passed)") }
            }
        }

        func until(_ condition: () -> Bool) async {
            for _ in 0..<1000 where !condition() { await Task.yield() }
        }

        static func key(_ text: String, _ type: NSEvent.EventType, code: UInt16, window: NSWindow, time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
            let characters = text == "<esc>" ? "\u{1b}" : text
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }

        static func code(_ key: String, _ index: Int) -> UInt16 { key == "<esc>" ? 53 : UInt16(100 + index) }

        static func describe(_ event: NSEvent) -> String {
            let text = event.keyCode == 53 ? "<esc>" : event.charactersIgnoringModifiers ?? "?"
            return event.type == .keyUp ? "^\(text)" : text
        }

        static var runtimes: [CEFRuntime] = []

        static func library() throws -> CEFShimLibrary {
            let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
            let nothing: @convention(c) () -> Int = { 0 }
            return try CEFShimLibrary.resolving { name in
                name == "cmux_shim_create_window" ? unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self) : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }

    private static func targets(_ count: Int) -> [LinkHintTarget] { (0..<count).map { LinkHintTarget(x: Double($0), y: 1, left: Double($0), top: 0) } }

    /// Case 1: a text field has the keyboard. Every key typed while the page answers, whatever it is, goes to the page
    /// once, in order, each key-up after its key-down.
    @Test func aFieldGetsEveryKeyOnceInOrderAfterTheFocusCheck() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        await harness.start()
        harness.type(["i", "e", " ", "d"])
        #expect(harness.sent.isEmpty, "a key went to the page before it answered: \(harness.sent)")
        harness.focus.give(true)
        await harness.until { !harness.controller.isActive }
        #expect(harness.sent == ["i", "^i", "e", "^e", " ", "^ ", "d", "^d"], "the page got \(harness.sent)")
        #expect(!harness.targets.isAsked, "the targets were collected for a page with a text field")
    }

    /// Case 2 with a slow page (review 6594559342 finding 2): no text field has the keyboard, and the targets take past
    /// the answer's bound. The bound covers the focus check only: the hint letters stay the session's, never reach the
    /// page (a page shortcut on the letter would run), and pick once the labels come.
    @Test func aSlowTargetCollectNeverSendsHintLettersToThePage() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        await harness.start()
        let label = Array(LinkHintSession.labels(count: 30))[7]
        harness.type(label.map(String.init))
        harness.focus.give(false)
        await harness.until { harness.targets.isAsked }
        harness.controller.answerTimedOut() // the bound passes while the targets are collected
        #expect(harness.controller.isActive && harness.sent.isEmpty, "the bound ended a hint session with no text field and sent its letters to the page: \(harness.sent)")
        harness.targets.give(Self.targets(30))
        await harness.until { !harness.controller.isActive }
        #expect(harness.sent.isEmpty, "a hint letter reached the page: \(harness.sent)")
    }

    /// Review 6597001821 finding 1: once the page said no text field has the keyboard, the held letters are hint keys.
    /// A click (or the keyboard leaving the page) while the targets are still collected ends the session, and the hint
    /// letters never reach the page (a page shortcut on the letter would run), as before #32537.
    @Test func aClickAfterThePageSaidNoFieldNeverSendsHintLettersToThePage() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        await harness.start()
        harness.type(["a", "s"])
        harness.focus.give(false)
        await harness.until { harness.targets.isAsked }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.shell.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        _ = harness.controller.inputWillDispatch(click)
        #expect(!harness.controller.isActive, "a click did not end the session")
        #expect(!harness.sent.contains("a") && !harness.sent.contains("s"), "a hint letter reached the page after a click: \(harness.sent)")
        harness.targets.give(Self.targets(30))
        await harness.until { false }
        #expect(!harness.sent.contains("a") && !harness.sent.contains("s"), "a late answer sent a hint letter: \(harness.sent)")
    }

    /// Review 6597001821 finding 2: after the page said no text field, Escape ends the session at once, and a key that
    /// is no hint key ends it and reaches the page at once; neither waits for a slow target collect.
    @Test func escapeOrAnotherKeyAfterNoFieldActsAtOnce() async throws {
        let escape = try Harness()
        defer { escape.shell.closeAfterTest() }
        await escape.start()
        escape.type(["a"])
        escape.focus.give(false)
        await escape.until { escape.targets.isAsked }
        escape.type(["<esc>"])
        #expect(!escape.controller.isActive, "Escape waited for the target collect")
        #expect(!escape.sent.contains("a"), "a hint letter reached the page: \(escape.sent)")
        let other = try Harness()
        defer { other.shell.closeAfterTest() }
        await other.start()
        other.type(["a"])
        other.focus.give(false)
        await other.until { other.targets.isAsked }
        other.type([" "])
        #expect(!other.controller.isActive, "a key that is no hint key waited for the target collect")
        #expect(other.sent.contains(" (passed)") && !other.sent.contains("a"), "the page got \(other.sent)")
    }

    /// Review 6599335161 finding 1: a key that is no hint key, held while the page answered, ends the session at the
    /// "no field" answer and goes to the page. If that key starts link hints again (link hints bound to a chord), the new
    /// session must live: the old session ends before its keys go to the page, never after.
    @Test func aHeldKeyThatStartsLinkHintsAgainKeepsTheNewSession() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        await harness.start()
        harness.type(["a", "<cmd-f>"])
        var restarted = false
        harness.controller.send = { [weak harness] keys in
            guard let harness else { return }
            harness.sent += keys.map(Harness.describe)
            if keys.contains(where: { $0.charactersIgnoringModifiers == "<cmd-f>" }), !restarted {
                restarted = true
                harness.controller.start(.follow, tab: harness.tab, window: harness.shell, isFocused: { true }, openInSplit: { _ in }, noLinks: {})
            }
        }
        harness.focus.give(false)
        await harness.until { restarted }
        #expect(restarted, "the held non-hint key did not reach the page")
        #expect(harness.controller.isActive, "the session the delivered key started was cancelled by the old one's end")
        harness.controller.cancel()
    }

    /// Review 6599335161 finding 2: keys held while the page answered and resolved at the "no field" answer: a held key
    /// that is no hint key ends the session and reaches the page with every key after it; a held Escape ends it and is
    /// its own; the hint letters before them never reach the page.
    @Test func heldKeysAtTheNoFieldAnswerEndTheSessionLikeLiveKeys() async throws {
        let other = try Harness()
        defer { other.shell.closeAfterTest() }
        await other.start()
        other.type(["a", " ", "b"])
        other.focus.give(false)
        await other.until { !other.controller.isActive }
        #expect(other.sent == [" ", "^ ", "b", "^b"], "the page got \(other.sent)")
        let escape = try Harness()
        defer { escape.shell.closeAfterTest() }
        await escape.start()
        escape.type(["a", "<esc>", "b"])
        escape.focus.give(false)
        await escape.until { !escape.controller.isActive }
        #expect(escape.sent == ["b", "^b"], "Escape: the page got \(escape.sent)")
    }

    /// Review 6603845634 finding 1 (a regression of e98112e): a label typed in full before the labels came is picked
    /// when they come, after their draw. A click or a new link-hints start during that draw (a few ms) cancelled the
    /// pick: it never clicked, and the labels the draw put on the page stayed there. The pick, once decided, removes
    /// the labels and acts, whatever comes during the draw.
    @Test func aPickDecidedWhenTheLabelsComeSurvivesAClickDuringTheirDraw() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        var asked: [String] = []
        let draw = Answer<BrowserJSValue>()
        harness.controller.script = { _, source in
            asked.append(source == LinkHintSession.removeScript ? "remove" : "draw")
            return source == LinkHintSession.removeScript ? .bool(false) : await draw.next()
        }
        await harness.start()
        let label = Array(LinkHintSession.labels(count: 30))[7]
        harness.type(label.map(String.init))
        harness.focus.give(false)
        await harness.until { harness.targets.isAsked }
        harness.targets.give(Self.targets(30))
        await harness.until { draw.isAsked }
        #expect(!harness.controller.isActive, "the pick did not end the session when the labels came")
        harness.controller.cancel() // a click (AppServices' mouse-down observer) or a new start, while the labels draw
        draw.give(.bool(true))
        await harness.until { asked.contains("remove") }
        #expect(asked.contains("remove"), "the decided pick was dropped: the labels it drew stay on the page and nothing was clicked (asked: \(asked))")
        #expect(harness.sent.isEmpty, "a hint letter reached the page: \(harness.sent)")
    }

    /// Review 6603845634 finding 2: the bound of an ended session fires after a new session started (its fire was taken
    /// off the main actor before the cancel). It must not end the new session, whose own bound still runs.
    @Test func anEndedSessionsBoundNeverEndsTheNextSession() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        await harness.start()
        let stale = harness.controller.boundForCurrentSession()
        harness.controller.cancel()
        await harness.start()
        harness.type(["i"])
        stale()
        #expect(harness.controller.isActive, "the ended session's bound ended the new session")
        #expect(harness.sent.isEmpty, "the new session's held key went to the page: \(harness.sent)")
        harness.controller.cancel()
    }

    /// Review 6603845634 finding 3: a start while a session holds a key that starts link hints again. The start's
    /// cancel delivers that key, which starts a session inside the start; the start must end that session too (its
    /// focus check must never answer for the session the start makes).
    @Test func aStartWhoseCancelStartsASessionLeavesOnlyItsOwnSession() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        let answers = Answers()
        harness.controller.focusAnswer = { _ in await answers.next() }
        await harness.start()
        harness.type(["<cmd-f>"])
        var inner = 0
        harness.controller.send = { [weak harness] keys in
            guard let harness else { return }
            harness.sent += keys.map(Harness.describe)
            if keys.contains(where: { $0.charactersIgnoringModifiers == "<cmd-f>" }), inner == 0 {
                inner += 1
                harness.controller.start(.follow, tab: harness.tab, window: harness.shell, isFocused: { true }, openInSplit: { _ in }, noLinks: {})
            }
        }
        harness.controller.start(.follow, tab: harness.tab, window: harness.shell, isFocused: { true }, openInSplit: { _ in }, noLinks: {})
        await harness.until { answers.asked >= 3 }
        #expect(inner == 1, "the held chord did not start a session inside the start")
        harness.type(["a", "b"]) // held by the start's own session, until its page answers
        answers.give(asked: 2, true) // the inner session's focus check (the 2nd asked) answers: "a text field has the keyboard"
        await harness.until { false }
        #expect(harness.controller.isActive, "the inner session's answer ended the start's own session")
        #expect(!harness.sent.contains("a"), "the inner session's answer gave the start's held keys to the page: \(harness.sent)")
        harness.controller.cancel()
    }

    /// Focus answers for several sessions: each waiter in the order asked; a cancelled one gets nil.
    @MainActor private final class Answers {
        private var waiters: [(id: Int, waiter: CheckedContinuation<Bool?, Never>)] = []
        private var cancelled: Set<Int> = []
        private(set) var asked = 0
        nonisolated deinit {}

        func next() async -> Bool? {
            asked += 1
            let id = asked
            return await withTaskCancellationHandler {
                await withCheckedContinuation { waiter in
                    if cancelled.remove(id) != nil { waiter.resume(returning: nil) } else { waiters.append((id, waiter)) }
                }
            } onCancel: {
                MainActor.assumeIsolated { self.cancel(id) }
            }
        }

        private func cancel(_ id: Int) {
            if let index = waiters.firstIndex(where: { $0.id == id }) { waiters.remove(at: index).waiter.resume(returning: nil) } else { cancelled.insert(id) }
        }

        /// Answers the `asked`-th question, if it still waits.
        func give(asked id: Int, _ value: Bool?) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).waiter.resume(returning: value)
        }
    }

    /// A click before the page answered ends the session: every held key goes to the page first, in order.
    @Test func aClickBeforeTheAnswerGivesEveryHeldKeyToThePageInOrder() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        await harness.start()
        harness.type(["i", "e"])
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.shell.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(!harness.controller.inputWillDispatch(click), "the click was taken")
        #expect(harness.sent == ["i", "^i", "e", "^e"] && !harness.controller.isActive, "the page got \(harness.sent)")
        harness.focus.give(true)
        await harness.until { false }
        #expect(harness.sent == ["i", "^i", "e", "^e"], "a late answer sent a key again: \(harness.sent)")
    }

    /// No answer to the focus check within the bound (a hung renderer): the held keys go to the page, once, in order.
    @Test func noFocusAnswerWithinTheBoundGivesTheKeysToThePage() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        await harness.start()
        harness.type(["i", "e"])
        harness.controller.answerTimedOut()
        #expect(harness.sent == ["i", "^i", "e", "^e"] && !harness.controller.isActive, "the page got \(harness.sent)")
        harness.focus.give(true)
        await harness.until { false }
        #expect(harness.sent.count == 4, "a late answer sent a key again: \(harness.sent)")
    }

    /// Review 6594559342 finding 1: Chromium's page window class exists only once the framework loaded, which can be
    /// after the first key of the process. A key Chromium sends back from a page window is still known as the page's;
    /// a new key in that page window is the session's.
    @Test func aKeyChromiumSentBackIsThePagesWhenChromiumLoadedAfterTheFirstKey() async throws {
        let harness = try Harness()
        defer { harness.shell.closeAfterTest() }
        let early = Harness.key("x", .keyDown, code: 7, window: harness.shell)
        harness.controller.noteKeyDown(early, in: harness.shell) // a key before Chromium loaded
        let pageClass: AnyClass = objc_lookUpClass("CefNSWindow") ?? {
            let made: AnyClass = objc_allocateClassPair(NSWindow.self, "CefNSWindow", 0)!
            objc_registerClassPair(made)
            return made
        }()
        let pageType = try #require(pageClass as? NSWindow.Type)
        let page = pageType.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        harness.shell.addChildWindow(page, ordered: .above)
        defer { harness.shell.removeChildWindow(page); page.closeAfterTest() }
        let f = Harness.key("f", .keyDown, code: 3, window: page, time: 9)
        harness.controller.noteKeyDown(f, in: page) // the page had the `f`
        await harness.start()
        harness.controller.noteKeyDown(f, in: page) // Chromium sends the `f` back: the same event
        #expect(!harness.controller.interceptKeyDown(f, in: page), "a key the page already had was taken by the session (the v6 double)")
        let i = Harness.key("i", .keyDown, code: 34, window: page, time: 9.01)
        harness.controller.noteKeyDown(i, in: page)
        #expect(harness.controller.interceptKeyDown(i, in: page), "a new key in the page window was not the session's")
        harness.controller.cancel()
    }
}
