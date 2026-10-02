import Foundation
import Testing
@testable import CmuxNextBrowser

/// CEF callback order -> BrowserTabState, without starting CEF.
@Suite struct CEFTabEventTests {
    private func makeTab() -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "t"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    @Test func fullNavigationFinishes() {
        let tab = makeTab()
        tab.load(URL(string: "https://a.example/")!)
        #expect(tab.state.phase == .provisional)
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: false, canGoForward: false))
        tab.handle(.loadStart(browser: 1, url: "https://a.example/"))
        #expect(tab.state.phase == .committed)
        tab.handle(.title(browser: 1, title: "A"))
        tab.handle(.loadEnd(browser: 1, httpStatus: 200))
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: true, canGoForward: false))
        #expect(tab.state.phase == .finished)
        #expect(tab.state.title == "A")
        #expect(tab.state.canGoBack)
        #expect(tab.state.url?.host() == "a.example")
    }

    /// Back reports the entry's title before the commit, and a page from
    /// the back/forward cache never sets it again: the commit keeps it
    /// rather than leaving the previous page's title in the record.
    @Test func backKeepsTheTitleReportedBeforeCommit() {
        let tab = makeTab()
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: false, canGoForward: false))
        tab.handle(.loadStart(browser: 1, url: "https://a.example/"))
        tab.handle(.title(browser: 1, title: "A"))
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: false, canGoForward: false))
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: true, canGoForward: false))
        tab.handle(.loadStart(browser: 1, url: "https://b.example/"))
        tab.handle(.title(browser: 1, title: "B"))
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: true, canGoForward: false))
        #expect(tab.state.title == "B")

        // Back to A: the title comes first, then the commit.
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: true, canGoForward: false))
        tab.handle(.title(browser: 1, title: "A"))
        tab.handle(.loadStart(browser: 1, url: "https://a.example/"))
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: false, canGoForward: true))
        #expect(tab.state.url?.host() == "a.example")
        #expect(tab.state.title == "A")

        // A new document that names itself only later starts untitled.
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: false, canGoForward: true))
        tab.handle(.loadStart(browser: 1, url: "https://c.example/"))
        #expect(tab.state.title == nil)
    }

    @Test func pageInitiatedNavigationStartsFromLoadingState() {
        let tab = makeTab()
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: false, canGoForward: false))
        #expect(tab.state.isLoading)
        tab.handle(.loadStart(browser: 1, url: "https://b.example/"))
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: false, canGoForward: false))
        #expect(tab.state.phase == .finished)
        #expect(tab.state.url?.host() == "b.example")
    }

    @Test func abortedLoadIsNotAnError() {
        let tab = makeTab()
        tab.load(URL(string: "https://a.example/")!)
        tab.handle(.loadError(browser: 1, code: -3, text: "net::ERR_ABORTED", url: "https://a.example/"))
        #expect(tab.state.loadError == nil)
    }

    @Test func networkErrorFails() {
        let tab = makeTab()
        tab.load(URL(string: "https://nope.example/")!)
        tab.handle(.loadError(browser: 1, code: -105, text: "net::ERR_NAME_NOT_RESOLVED", url: "https://nope.example/"))
        #expect(tab.state.loadError?.code == -105)
        #expect(tab.state.loadError?.domain == "net")
    }

    @Test func loadBeforeCreationIsQueued() {
        let tab = makeTab()
        tab.load(URL(string: "https://queued.example/")!)
        #expect(tab.browserID == nil)
        #expect(tab.initialURLString == "https://queued.example/")
        #expect(tab.presentation == .childWindow)
    }

    @Test func pageCloseBecomesAnIntent() {
        final class Recorder: BrowserTabDelegate {
            var closes = 0
            func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
                if case .close = intent { closes += 1 }
            }
        }
        let tab = makeTab()
        let recorder = Recorder()
        tab.delegate = recorder
        tab.handle(.closeRequested(browser: 1))
        #expect(recorder.closes == 1)
    }
}
