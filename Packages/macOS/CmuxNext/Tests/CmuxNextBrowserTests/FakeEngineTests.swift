import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

@Suite struct FakeEngineTests {
    let a = URL(string: "https://a.example/")!
    let b = URL(string: "https://b.example/")!
    let c = URL(string: "https://c.example/")!

    @Test func registryCreatesTabsAndReportsUnavailableEngines() async throws {
        let registry = BrowserEngineRegistry(engines: [MockBrowserEngine(), CEFEngine()])
        #expect(registry.availableKinds == [.webkit])

        let tab = try await registry.makeTab(kind: .webkit, BrowserTabConfiguration(initialURL: a))
        #expect(tab.engineKind == .webkit)
        #expect(tab.state.url == a)
        #expect(tab.state.phase == .finished)

        await #expect(throws: BrowserEngineError.self) {
            _ = try await registry.makeTab(kind: .cef, BrowserTabConfiguration())
        }
        do {
            _ = try await registry.makeTab(kind: .cef, BrowserTabConfiguration())
        } catch BrowserEngineError.engineUnavailable(let kind, let reason) {
            #expect(kind == .cef)
            #expect(!reason.isEmpty)
        }

        let empty = BrowserEngineRegistry()
        await #expect(throws: BrowserEngineError.engineNotRegistered(.webkit)) {
            _ = try await empty.makeTab(kind: .webkit, BrowserTabConfiguration())
        }
    }

    @Test func backForwardHistory() {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        tab.load(a)
        tab.load(b)
        tab.load(c)
        #expect(tab.state.canGoBack)
        #expect(!tab.state.canGoForward)

        tab.goBack()
        #expect(tab.state.url == b)
        #expect(tab.state.canGoForward)
        tab.goBack()
        #expect(tab.state.url == a)
        #expect(!tab.state.canGoBack)

        tab.goForward()
        #expect(tab.state.url == b)

        // Loading a new page drops the forward list.
        tab.load(a)
        #expect(!tab.state.canGoForward)
        #expect(tab.state.canGoBack)
    }

    @Test func manualEventsReproduceEngineCallbackOrder() {
        let tab = MockBrowserEngine(completesNavigationsImmediately: false).makeMockTab(BrowserTabConfiguration())
        tab.load(a)
        #expect(tab.state.phase == .provisional)
        let active = tab.state.activeNavigation!

        // A second load supersedes the first; the first one's failure is late.
        tab.load(b)
        let second = tab.state.activeNavigation!
        tab.simulate(.failed(active, BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, message: "timeout")))
        #expect(tab.state.loadError == nil)
        tab.simulate(.committed(second, url: b))
        tab.simulate(.finished(second))
        #expect(tab.state.phase == .finished)
        #expect(tab.state.url == b)
    }

    @Test func stopAndReload() {
        let tab = MockBrowserEngine(completesNavigationsImmediately: false).makeMockTab(BrowserTabConfiguration())
        tab.load(a)
        tab.stop()
        #expect(!tab.state.isLoading)
        tab.reload()
        #expect(tab.state.isLoading)
        #expect(tab.commands == [.load(a), .stop, .reload])
    }

    @Test func zoomHelpersUseTheLadder() {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(zoom: 1.25))
        #expect(tab.state.zoom == 1.25)
        tab.zoomIn()
        #expect(tab.state.zoom == 1.5)
        tab.zoomOut()
        tab.zoomOut()
        #expect(tab.state.zoom == 1.1)
        tab.resetZoom()
        #expect(tab.state.zoom == 1)
    }

    @Test func promptsResolveOnceAndCloseDismissesThem() async {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let camera = Task { await tab.presentPrompt(.permission(.camera), origin: "https://meet.example") }
        while tab.pendingPrompts.count < 1 { await Task.yield() }
        let confirm = Task { await tab.presentPrompt(.confirm(message: "Leave?"), origin: "https://a.example") }
        while tab.pendingPrompts.count < 2 { await Task.yield() }

        let first = tab.pendingPrompts[0]
        #expect(first.kind == .permission(.camera))
        first.respond(.allow)
        first.respond(.deny)
        #expect(first.isResolved)
        #expect(tab.pendingPrompts.count == 1)

        tab.close()
        #expect(tab.pendingPrompts.isEmpty)
        #expect(await camera.value == .allow)
        #expect(await confirm.value == .cancel)
    }

    @Test func findCountsMatches() async {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        tab.pageText = "Apple apple APPLE pear"
        let insensitive = await tab.find("apple", direction: .forward, caseSensitive: false)
        #expect(insensitive == BrowserFindResult(matchFound: true, matchCount: 3))
        let sensitive = await tab.find("apple", direction: .forward, caseSensitive: true)
        #expect(sensitive.matchCount == 1)
        #expect(await tab.find("", direction: .forward, caseSensitive: false) == .none)
    }

    @Test func intentsReachTheDelegate() {
        final class Recorder: BrowserTabDelegate {
            var urls: [URL] = []
            func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
                if case .openURL(let url, _) = intent { urls.append(url) }
            }
        }
        let recorder = Recorder()
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        tab.delegate = recorder
        tab.emit(.openURL(a, .backgroundTab))
        #expect(recorder.urls == [a])
    }

    @Test func closedTabsRefuseWork() async {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        tab.close()
        tab.close()
        #expect(tab.commands == [.close])
        await #expect(throws: BrowserTabError.closed) { _ = try await tab.evaluate("1") }
        await #expect(throws: BrowserTabError.closed) { _ = try await tab.snapshot() }
    }

    @Test func historyRecorderRecordsFinishedLoads() async {
        let history = InMemoryBrowserHistory()
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let recorder = BrowserHistoryRecorder(tab: tab, store: history)
        tab.load(a)
        for _ in 0..<5 { await Task.yield() }
        tab.load(b)
        for _ in 0..<5 { await Task.yield() }
        #expect(Set(history.entries.map(\.url)) == [a, b])
        recorder.stop()
    }

    @Test func chromeCommandsMatchDefaultShortcuts() throws {
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0
            ))
        }
        #expect(BrowserChromeCommand.matching(try key("l", .command)) == .focusAddressBar)
        #expect(BrowserChromeCommand.matching(try key("g", [.command, .shift])) == .findPrevious)
        #expect(BrowserChromeCommand.matching(try key("+", [.command, .shift])) == .zoomIn)
        #expect(BrowserChromeCommand.matching(try key("i", [.command, .option])) == .showDevTools)
        #expect(BrowserChromeCommand.matching(try key("t", .command)) == nil)
        #expect(BrowserChromeCommand.matching(try key("l", [])) == nil)
    }
}
