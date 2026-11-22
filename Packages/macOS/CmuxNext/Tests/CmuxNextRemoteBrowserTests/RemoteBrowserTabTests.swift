import AppKit
import CmuxNextBrowser
import Testing
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView

#if DEBUG
/// A remote tab routes keys like a local CEF tab: app shortcuts through the
/// host's key router first, everything else to the remote page, and keys the
/// page did not handle come back as the same intents a local tab sends.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteBrowserTabTests {
    @Test func appShortcutsNeverReachTheRemotePage() {
        let (tab, channel, router, _) = Self.make()
        router.claims = [Self.chord("t")]
        #expect(tab.handleKeyEquivalent(Self.key("t", [.command])))
        #expect(router.offered.count == 1)
        #expect(channel.keys.isEmpty)
    }

    @Test func chordsTheAppDoesNotClaimGoToThePage() {
        let (tab, channel, router, _) = Self.make()
        #expect(tab.handleKeyEquivalent(Self.key("c", [.command])))
        #expect(router.offered.count == 1)
        #expect(channel.keys.map(\.charactersIgnoringModifiers) == ["c"])
        #expect(channel.keys.first?.modifierFlags.contains(.command) == true)
    }

    @Test func plainKeysGoToThePageWithoutTheRouter() {
        let (tab, channel, router, _) = Self.make()
        tab.handleKey(Self.key("a", []))
        #expect(router.offered.isEmpty)
        #expect(channel.keys.map(\.charactersIgnoringModifiers) == ["a"])
    }

    @Test func browserFocusModeGivesThePageEveryChord() {
        let (tab, channel, router, _) = Self.make()
        router.claims = [Self.chord("t")]
        router.pageOwnsAll = true
        #expect(tab.handleKeyEquivalent(Self.key("t", [.command])))
        #expect(channel.keys.count == 1)
    }

    @Test func cmdClickReachesThePageWithTheCommandModifierAndClickCount() throws {
        let (tab, channel, _, _) = Self.make()
        tab.handlePointer(Self.mouse(.leftMouseDown, at: CGPoint(x: 40, y: 30), [.command], clicks: 1))
        tab.handlePointer(Self.mouse(.leftMouseUp, at: CGPoint(x: 40, y: 30), [.command], clicks: 1))
        #expect(channel.pointers.map(\.event.type) == [.leftMouseDown, .leftMouseUp])
        let down = try #require(channel.pointers.first)
        #expect(down.event.modifierFlags.contains(.command))
        #expect(down.event.clickCount == 1)
    }

    @Test func aLetterThePageDidNotHandleBecomesAPageKeyIntent() {
        let (tab, _, _, delegate) = Self.make()
        tab.handleKey(Self.key("f", [.shift], characters: "F"))
        tab.keyUnhandled(inputSeq: 1)
        #expect(delegate.pageKeys == [BrowserPageKey(character: "f", shift: true)])
    }

    @Test func escapeThePageDidNotHandleBecomesUnhandledEscape() {
        let (tab, _, _, delegate) = Self.make()
        tab.handleKey(Self.key("\u{1B}", [], keyCode: 53))
        tab.keyUnhandled(inputSeq: 1)
        #expect(delegate.escapes == 1)
    }

    @Test func unknownOrRepeatedUnhandledSeqsChangeNothing() {
        let (tab, _, _, delegate) = Self.make()
        tab.handleKey(Self.key("f", []))
        tab.keyUnhandled(inputSeq: 9)
        tab.keyUnhandled(inputSeq: 1)
        tab.keyUnhandled(inputSeq: 1)
        #expect(delegate.pageKeys.count == 1)
    }

    @Test func chordsAndDigitsThePageDidNotHandleAreNotPageKeys() {
        let (tab, _, _, delegate) = Self.make()
        tab.handleKeyEquivalent(Self.key("f", [.command]))
        tab.handleKey(Self.key("1", []))
        tab.keyUnhandled(inputSeq: 1)
        tab.keyUnhandled(inputSeq: 2)
        #expect(delegate.pageKeys.isEmpty)
        #expect(delegate.escapes == 0)
    }

    @Test func historyAndVisibilityGoToTheHost() {
        let (tab, channel, _, _) = Self.make()
        tab.goBack()
        tab.goForward()
        tab.reload()
        tab.stop()
        tab.setContentVisible(false)
        #expect(channel.history == [.back, .forward, .reload, .stop])
        #expect(channel.visible == [false])
        #expect(tab.contentView.isHidden)
        #expect(tab.presentation == .inView)
    }

    // MARK: Fixtures

    private static func make() -> (RemoteBrowserTab, RecordingChannel, FakeRouter, RecordingDelegate) {
        let channel = RecordingChannel()
        let pane = RemoteBrowserPane(source: MockRemoteStreamSource(width: 64, height: 64))
        let tab = RemoteBrowserTab(
            id: BrowserTabID.random(), profile: BrowserProfileID.default, url: URL(string: "https://example.com/")!, pane: pane, channel: channel)
        let router = FakeRouter()
        let delegate = RecordingDelegate()
        tab.keyRouter = router
        tab.delegate = delegate
        return (tab, channel, router, delegate)
    }

    static func chord(_ key: String) -> String { "cmd-\(key)" }

    static func key(_ key: String, _ flags: NSEvent.ModifierFlags, characters: String? = nil, keyCode: UInt16 = 3) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters ?? key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
    }

    static func mouse(_ type: NSEvent.EventType, at point: CGPoint, _ flags: NSEvent.ModifierFlags, clicks: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
}

@MainActor
private final class RecordingChannel: RemoteBrowserPageChannel {
    var keys: [NSEvent] = []
    var pointers: [(event: NSEvent, point: CGPoint)] = []
    var history: [RemoteBrowserHistoryOp] = []
    var visible: [Bool] = []
    var loads: [URL] = []

    func sendKey(_ event: NSEvent) -> UInt32 {
        keys.append(event)
        return UInt32(keys.count)
    }

    func sendPointer(_ event: NSEvent, at point: CGPoint) { pointers.append((event, point)) }
    func history(_ op: RemoteBrowserHistoryOp) { history.append(op) }
    func setVisible(_ visible: Bool) { self.visible.append(visible) }
    func load(_ url: URL) { loads.append(url) }
    func close() {}
}

@MainActor
private final class FakeRouter: BrowserKeyRouting {
    var claims: Set<String> = []
    var pageOwnsAll = false
    var offered: [NSEvent] = []

    func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition {
        offered.append(event)
        let name = "cmd-\(event.charactersIgnoringModifiers ?? "")"
        return !pageOwnsAll && claims.contains(name) ? .handledByHost : .passToPage
    }

    func pageOwnsAllKeys(_ tab: any BrowserTab) -> Bool { pageOwnsAll }
}

@MainActor
private final class RecordingDelegate: BrowserTabDelegate {
    var pageKeys: [BrowserPageKey] = []
    var escapes = 0

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        switch intent {
        case let .unhandledKey(key): pageKeys.append(key)
        case .unhandledEscape: escapes += 1
        default: break
        }
    }
}
#endif
