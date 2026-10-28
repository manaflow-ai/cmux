import AppKit
@testable import CmuxNextBrowser
import Testing

/// Keys of a hosted page: the KeyRouter decided in `CmuxApplication.sendEvent`
/// before the page view sees a key; a chord the page leaves unhandled comes back as KEY_UNHANDLED
/// with the input seq of the frame that carried it and goes to the held cmux action or the menus.
@MainActor
@Suite struct ChromiumHostPageViewKeyTests {
    static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    static func receipt(_ browser: Int32, _ seq: UInt32) -> ChromiumHostInputReceipt {
        ChromiumHostInputReceipt(browser: browser, seq: seq)
    }

    // MARK: ChromiumHostKeyDowns

    @Test func aReportTakesExactlyItsKey() throws {
        var keys = ChromiumHostKeyDowns()
        let first = try Self.key("k", keyCode: 40, modifiers: .command)
        let second = try Self.key("k", keyCode: 40, modifiers: .command)
        keys.record(first, Self.receipt(1, 3))
        keys.record(second, Self.receipt(1, 9))
        // The page handled the first Cmd-K (no report) and left the second.
        let reported = keys.take(9, browser: 1)
        #expect(reported === second, "the report names its own key, not an older one")
        let again = keys.take(9, browser: 1)
        let none = keys.take(0, browser: 1)
        #expect(again == nil, "a key runs at most once")
        #expect(none == nil, "seq 0 is no key")
        #expect(keys.count == 1, "the handled key stays until the limit drops it")
    }

    @Test func aReportFromOneTabLeavesAnotherTabsKeys() throws {
        var keys = ChromiumHostKeyDowns()
        let toA = try Self.key("f", keyCode: 3, modifiers: .command)
        let toB = try Self.key("g", keyCode: 5, modifiers: .command)
        keys.record(toA, Self.receipt(1, 5))
        keys.record(toB, Self.receipt(2, 6))
        let wrongBrowser = keys.take(5, browser: 2)
        #expect(wrongBrowser == nil, "a seq is the browser's own")
        let fromB = keys.take(6, browser: 2)
        let fromA = keys.take(5, browser: 1)
        #expect(fromB === toB)
        #expect(fromA === toA, "tab B's report released nothing of tab A")
    }

    @Test func aPageThatNeverReportsHoldsAtMostTheLimit() throws {
        var keys = ChromiumHostKeyDowns()
        let event = try Self.key("k", keyCode: 40, modifiers: .command)
        for seq in 1...UInt32(ChromiumHostKeyDowns.limit + 5) { keys.record(event, Self.receipt(1, seq)) }
        #expect(keys.count == ChromiumHostKeyDowns.limit)
        let dropped = keys.take(5, browser: 1)
        let oldest = keys.take(6, browser: 1)
        #expect(dropped == nil, "the oldest are dropped first")
        #expect(oldest === event)
    }

    // MARK: KEY_UNHANDLED

    @Test func aChordReportDecodesWithItsSeqAndOtherReportsStayAsBefore() {
        #expect(CEFShimEvent(kind: 28, browser: 7, request: 41, a: 0x4B, b: 2 | 1, s1: "", s2: "")
            == .keyUnhandledChord(browser: 7, seq: 41))
        #expect(CEFShimEvent(kind: 28, browser: 7, request: -1, a: 0x4B, b: 2, s1: "", s2: "")
            == .keyUnhandledChord(browser: 7, seq: .max), "the seq comes as its bit pattern")
        #expect(CEFShimEvent(kind: 28, browser: 7, request: 0, a: 0x1B, b: 0, s1: "", s2: "")
            == .keyUnhandled(browser: 7, keyCode: 0x1B, shift: false))
        #expect(CEFShimEvent(kind: 28, browser: 7, request: 0, a: 0x46, b: 1, s1: "", s2: "")
            == .keyUnhandled(browser: 7, keyCode: 0x46, shift: true))
        #expect(CEFShimEvent.keyUnhandledChord(browser: 7, seq: 41).browserID == 7)
    }

    @Test func onlyCommandAndControlChordsAreReported() {
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
    /// A page view with the keyboard in a window, the key frames it sends, and a writer that stamps
    /// each frame for browser 4 with the next input seq.
    @MainActor final class Rig {
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view)
        let window: NSWindow
        var keyFrames: [ChromiumHostFrame] = []
        var lastSeq: UInt32 = 0

        init(reports: Bool = true) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(page)
            page.hostReportsUnhandledKeys = reports
            page.sink = { [unowned self] frame in
                lastSeq += 1
                if frame.kind == .key { keyFrames.append(frame) }
                return ChromiumHostInputReceipt(browser: 4, seq: lastSeq)
            }
        }

        func close() {
            page.removeFromSuperview()
            window.close()
        }
    }

    @Test func aChordGoesToThePageAndComesBackByItsInputSeq() throws {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.window.makeFirstResponder(rig.page))
        let cmdK = try Self.key("k", keyCode: 40, modifiers: .command)
        let plainK = try Self.key("k", keyCode: 40)
        #expect(rig.page.performKeyEquivalent(with: cmdK), "the page has the chord before the menu")
        let chordSeq = rig.lastSeq
        rig.page.keyDown(with: plainK)
        #expect(rig.keyFrames.map { $0.v[1] } == [40, 40])
        #expect(rig.keyFrames.allSatisfy { $0.v[3] == 0 }, "the seq is the header's, not a field of its own")
        #expect(rig.page.keyDowns.count == 1, "only the chord is held")
        let plain = rig.page.takeUnhandledKey(seq: rig.lastSeq, browser: 4)
        let otherBrowser = rig.page.takeUnhandledKey(seq: chordSeq, browser: 5)
        let unhandled = rig.page.takeUnhandledKey(seq: chordSeq, browser: 4)
        let again = rig.page.takeUnhandledKey(seq: chordSeq, browser: 4)
        #expect(plain == nil)
        #expect(otherBrowser == nil)
        #expect(unhandled === cmdK)
        #expect(again == nil)
    }

    /// Until the host reports unhandled keys, the menu keeps every chord and nothing is held.
    @Test func aHostThatReportsNothingLeavesChordsToTheMenu() throws {
        let rig = Rig(reports: false)
        defer { rig.close() }
        #expect(rig.window.makeFirstResponder(rig.page))
        let cmdQ = try Self.key("q", keyCode: 12, modifiers: .command)
        #expect(!rig.page.performKeyEquivalent(with: cmdQ), "Cmd-Q reached no menu")
        rig.page.keyDown(with: cmdQ)
        #expect(rig.page.keyDowns.count == 0, "a key no report can come for is held")
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
        inProcess.hostReportsUnhandledKeys = true
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
        let gone = rig.page.takeUnhandledKey(seq: rig.lastSeq, browser: 4)
        #expect(gone == nil)
    }
    #endif
}
