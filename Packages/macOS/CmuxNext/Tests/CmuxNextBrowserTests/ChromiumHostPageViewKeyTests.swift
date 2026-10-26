import AppKit
@testable import CmuxNextBrowser
import Testing

/// Keys of a hosted page (p01-process-030): the KeyRouter decided in `CmuxApplication.sendEvent`
/// before the page view sees a key; a chord the page leaves unhandled comes back as KEY_UNHANDLED
/// with the key seq its frame carried and goes to the held cmux action or the menus.
@MainActor
@Suite struct ChromiumHostPageViewKeyTests {
    static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    // MARK: ChromiumHostKeyDowns

    @Test func aReportReleasesItsKeyAndEveryOlderOne() throws {
        var keys = ChromiumHostKeyDowns()
        let cmdA = try Self.key("a", keyCode: 0, modifiers: .command)
        let cmdF = try Self.key("f", keyCode: 3, modifiers: .command)
        let cmdK = try Self.key("k", keyCode: 40, modifiers: .command)
        let seqs = [keys.record(cmdA), keys.record(cmdF), keys.record(cmdK)]
        #expect(seqs == [1, 2, 3])
        let reported = keys.take(2)
        #expect(reported === cmdF, "the report names the key it carries")
        #expect(keys.count == 1, "Cmd-A, which the page handled, is released with it")
        let handled = keys.take(1)
        let again = keys.take(2)
        let none = keys.take(0)
        #expect(handled == nil)
        #expect(again == nil, "a key runs at most once")
        #expect(none == nil, "seq 0 is no key")
        let newest = keys.take(3)
        #expect(newest === cmdK)
    }

    @Test func aPageThatNeverReportsHoldsAtMostTheLimit() throws {
        var keys = ChromiumHostKeyDowns()
        let event = try Self.key("k", keyCode: 40, modifiers: .command)
        for _ in 0..<(ChromiumHostKeyDowns.limit + 5) { _ = keys.record(event) }
        #expect(keys.count == ChromiumHostKeyDowns.limit)
        let dropped = keys.take(5)
        let oldest = keys.take(6)
        #expect(dropped == nil, "the oldest are dropped first")
        #expect(oldest === event)
    }

    // MARK: KEY_UNHANDLED

    @Test func aChordReportDecodesWithItsSeqAndOtherReportsStayAsBefore() {
        #expect(CEFShimEvent(kind: 28, browser: 7, request: 41, a: 0x4B, b: 2 | 1, s1: "", s2: "")
            == .keyUnhandledChord(browser: 7, seq: 41))
        #expect(CEFShimEvent(kind: 28, browser: 7, request: 9, a: 0x1B, b: 0, s1: "", s2: "")
            == .keyUnhandled(browser: 7, keyCode: 0x1B, shift: false))
        #expect(CEFShimEvent(kind: 28, browser: 7, request: 0, a: 0x46, b: 1, s1: "", s2: "")
            == .keyUnhandled(browser: 7, keyCode: 0x46, shift: true))
        #expect(CEFShimEvent.keyUnhandledChord(browser: 7, seq: 41).browserID == 7)
    }

    @Test func onlyCommandAndControlChordsCarryASeq() {
        #expect(ChromiumHostPageView.reportsUnhandled([.command]))
        #expect(ChromiumHostPageView.reportsUnhandled([.control, .shift]))
        #expect(!ChromiumHostPageView.reportsUnhandled([.option]))
        #expect(!ChromiumHostPageView.reportsUnhandled([.shift]))
        #expect(!ChromiumHostPageView.reportsUnhandled([]))
    }

    /// What a re-dispatch target got, and whether the page view stood aside meanwhile.
    @MainActor final class Redispatches {
        var events: [NSEvent] = []
        var whileRedispatching: [Bool] = []
    }

    @Test func redispatchGoesToTheTargetWhileThePageViewStandsAside() throws {
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), inputTarget: .view)
        let seen = Redispatches()
        page.redispatchTarget = { [unowned page] event in
            seen.events.append(event)
            seen.whileRedispatching.append(page.isRedispatching)
            return true
        }
        let event = try Self.key("k", keyCode: 40, modifiers: .command)
        #expect(page.redispatch(event))
        #expect(seen.events.count == 1 && seen.events.first === event)
        #expect(seen.whileRedispatching == [true])
        #expect(!page.isRedispatching)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// A page view with the keyboard in a window, and the key frames it sends.
    @MainActor final class Rig {
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view)
        let window: NSWindow
        var keyFrames: [ChromiumHostFrame] = []

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(page)
            page.sink = { [unowned self] frame in if frame.kind == .key { keyFrames.append(frame) } }
        }

        func close() {
            page.removeFromSuperview()
            window.close()
        }
    }

    @Test func aChordGoesToThePageWithASeqAndComesBackByIt() throws {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.window.makeFirstResponder(rig.page))
        let cmdK = try Self.key("k", keyCode: 40, modifiers: .command)
        let plainK = try Self.key("k", keyCode: 40)
        #expect(rig.page.performKeyEquivalent(with: cmdK), "the page has the chord before the menu")
        rig.page.keyDown(with: plainK)
        #expect(rig.keyFrames.map { $0.v[3] } == [1, 0], "only the chord carries a key seq")
        #expect(rig.keyFrames.map { $0.v[1] } == [40, 40])
        let unhandled = rig.page.takeUnhandledKey(seq: 1)
        let again = rig.page.takeUnhandledKey(seq: 1)
        #expect(unhandled === cmdK)
        #expect(again == nil)
    }

    @Test func thePageViewTakesNoChordItDoesNotHaveTheKeyboardFor() throws {
        let rig = Rig()
        defer { rig.close() }
        let cmdK = try Self.key("k", keyCode: 40, modifiers: .command)
        let optionK = try Self.key("k", keyCode: 40, modifiers: .option)
        #expect(!rig.page.performKeyEquivalent(with: cmdK), "not the first responder")
        #expect(rig.window.makeFirstResponder(rig.page))
        #expect(!rig.page.performKeyEquivalent(with: optionK), "an Option key is typing, not a key equivalent")
        rig.page.redispatchTarget = { [unowned page = rig.page] event in page.performKeyEquivalent(with: event) }
        #expect(!rig.page.redispatch(cmdK), "a re-dispatched key never goes back to the page")
        #expect(rig.keyFrames.isEmpty)

        let inProcess = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), inputTarget: .pageWindow)
        rig.window.contentView?.addSubview(inProcess)
        defer { inProcess.removeFromSuperview() }
        #expect(!inProcess.performKeyEquivalent(with: cmdK), "the page window takes an in-process page's keys")
    }

    @Test func leavingTheWindowDropsTheHeldKeys() throws {
        let rig = Rig()
        defer { rig.close() }
        let cmdW = try Self.key("w", keyCode: 13, modifiers: .command)
        #expect(rig.window.makeFirstResponder(rig.page))
        #expect(rig.page.performKeyEquivalent(with: cmdW))
        #expect(rig.page.keyDowns.count == 1)
        rig.page.removeFromSuperview()
        #expect(rig.page.keyDowns.count == 0)
        let gone = rig.page.takeUnhandledKey(seq: 1)
        #expect(gone == nil)
    }
    #endif
}
