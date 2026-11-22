import Testing
@testable import CmuxNextBrowser

/// Quitting closes every Chromium browser before CefShutdown. Those closes
/// end the engine, not the tabs: a tab must not ask cmux to close it, or
/// the daemon deletes it and relaunch shows the workspace without its
/// browser tabs. A page that closes itself (`window.close()`) still asks.
@MainActor
@Suite(.serialized) struct CEFQuitCloseTests {
    private final class Recorder: BrowserTabDelegate {
        var intents: [String] = []
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            intents.append(String(describing: intent))
        }
    }

    private func makeTab(browser: Int32) -> (CEFTab, Recorder) {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "quit-\(browser)"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let recorder = Recorder()
        tab.delegate = recorder
        runtime.register(tab, browser: browser)
        return (tab, recorder)
    }

    @Test func aBrowserClosedByQuitDoesNotCloseItsTab() {
        let runtime = CEFRuntime.shared
        let (_, recorder) = makeTab(browser: 70_201)
        defer { runtime.tabsByBrowser[70_201] = nil }
        var sequence = CEFShutdownSequence(liveBrowsers: 1, windows: 0)
        sequence.begin()
        runtime.shutdownSequence = sequence
        defer { runtime.shutdownSequence = nil }

        runtime.handle(.beforeClose(browser: 70_201))
        #expect(recorder.intents.isEmpty, "quit must keep the tab in the daemon")
    }

    @Test func aPageThatClosesItselfStillClosesItsTab() {
        let runtime = CEFRuntime.shared
        let (_, recorder) = makeTab(browser: 70_202)
        defer { runtime.tabsByBrowser[70_202] = nil }
        runtime.handle(.beforeClose(browser: 70_202))
        #expect(recorder.intents.count == 1)
        #expect(recorder.intents.first?.hasPrefix("close") == true)
    }
}
