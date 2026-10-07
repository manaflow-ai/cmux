import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Content process failures: the reducer, the CEF status mapping and the
/// CEF tab's reaction to renderer crash, kill and hang callbacks.
@Suite struct ProcessExitTests {
    let a = URL(string: "https://a.example/")!
    let nav1 = BrowserNavigationID(rawValue: 1)
    let nav2 = BrowserNavigationID(rawValue: 2)

    // MARK: Reducer

    @Test func exitEndsTheLoadAndKeepsTheURL() {
        var machine = BrowserTabStateMachine()
        machine.apply(.started(nav1, url: a))
        machine.apply(.committed(nav1, url: a))
        machine.apply(.processExited(BrowserProcessExit(reason: .crashed, code: 11)))
        #expect(machine.state.processExit?.reason == .crashed)
        #expect(!machine.state.isLoading)
        #expect(machine.state.url == a)
        #expect(machine.state.loadError == nil)
    }

    @Test func nextNavigationClearsTheExit() {
        var machine = BrowserTabStateMachine()
        machine.apply(.started(nav1, url: a))
        machine.apply(.finished(nav1))
        machine.apply(.processExited(BrowserProcessExit(reason: .killed, code: 9)))
        machine.apply(.started(nav2, url: nil))
        #expect(machine.state.processExit == nil)
        #expect(machine.state.url == a)
    }

    @Test func goneWinsOverUnresponsiveAndOverALoadError() {
        var machine = BrowserTabStateMachine()
        machine.apply(.started(nav1, url: a))
        machine.apply(.failed(nav1, BrowserLoadError(domain: "net", code: -105, message: "x", failingURL: a)))
        machine.apply(.unresponsiveChanged(true))
        #expect(machine.state.isUnresponsive)
        machine.apply(.processExited(BrowserProcessExit(reason: .crashed)))
        #expect(!machine.state.isUnresponsive)
        #expect(machine.state.loadError == nil)
        machine.apply(.unresponsiveChanged(true))
        #expect(!machine.state.isUnresponsive, "a gone page cannot hang")
    }

    @Test func cefStatusesMapToReasons() {
        #expect(BrowserProcessExit.cef(status: 0, code: 256).reason == .abnormal)
        #expect(BrowserProcessExit.cef(status: 1, code: 9).reason == .killed)
        #expect(BrowserProcessExit.cef(status: 2, code: 11).reason == .crashed)
        #expect(BrowserProcessExit.cef(status: 3, code: 0).reason == .outOfMemory)
        #expect(BrowserProcessExit.cef(status: 4, code: 0).reason == .launchFailed)
        #expect(BrowserProcessExit.cef(status: 5, code: 0).reason == .integrityFailure)
        #expect(BrowserProcessExit.cef(status: 99, code: 0).reason == .abnormal)
        #expect(BrowserProcessExit.cef(status: 3, code: 0).code == nil)
    }

    @Test func codeDescriptionReadsWaitStatus() {
        #expect(BrowserProcessExit(reason: .crashed, code: 11).codeDescription == "SIGSEGV")
        #expect(BrowserProcessExit(reason: .crashed, code: 139).codeDescription == "SIGSEGV")
        #expect(BrowserProcessExit(reason: .killed, code: 9).codeDescription == "SIGKILL")
        #expect(BrowserProcessExit(reason: .abnormal, code: 3 << 8).codeDescription == "exit 3")
        #expect(BrowserProcessExit(reason: .crashed, code: 30).codeDescription == "signal 30")
        #expect(BrowserProcessExit(reason: .crashed, code: nil).codeDescription == nil)
    }

    // MARK: CEF tab

    private func makeTab() -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "exit"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    @Test func rendererCrashShowsTheSadTab() {
        let tab = makeTab()
        tab.load(a)
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: false, canGoForward: false))
        tab.handle(.renderTerminated(browser: 1, status: 2, code: 11, text: "crashed"))
        #expect(tab.state.processExit == BrowserProcessExit(reason: .crashed, code: 11))
        #expect(!tab.state.isLoading)
        #expect(tab.state.url == a)
    }

    @Test func killedAndOutOfMemoryKeepTheirReason() {
        let tab = makeTab()
        tab.load(a)
        tab.handle(.renderTerminated(browser: 1, status: 1, code: 9, text: ""))
        #expect(tab.state.processExit?.reason == .killed)
        tab.reload()
        tab.handle(.renderTerminated(browser: 1, status: 3, code: 0, text: ""))
        #expect(tab.state.processExit?.reason == .outOfMemory)
    }

    @Test func hangShowsAndClearsUnresponsive() {
        let tab = makeTab()
        tab.load(a)
        tab.handle(.renderUnresponsive(browser: 1))
        #expect(tab.state.isUnresponsive)
        tab.handle(.renderResponsive(browser: 1))
        #expect(!tab.state.isUnresponsive)
    }

    @Test func reloadRecoversAndKeepsTheURL() {
        let tab = makeTab()
        tab.load(a)
        tab.handle(.renderTerminated(browser: 1, status: 2, code: 11, text: ""))
        tab.reload()
        #expect(tab.state.processExit == nil)
        #expect(tab.state.isLoading)
        #expect(tab.state.url == a)
    }

    @Test func backgroundCrashReloadsWhenShown() {
        let tab = makeTab()
        tab.load(a)
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: false, canGoForward: false))
        tab.handle(.renderTerminated(browser: 1, status: 2, code: 11, text: ""))
        #expect(tab.state.processExit != nil)
        tab.contentDidAppear(in: CEFTabContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(tab.state.processExit == nil, "a tab that crashed in the background reloads when it is shown")
        #expect(tab.state.isLoading)
    }

    @Test func visibleCrashWaitsForTheUser() {
        let tab = makeTab()
        tab.load(a)
        tab.contentDidAppear(in: CEFTabContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        tab.handle(.renderTerminated(browser: 1, status: 2, code: 11, text: ""))
        tab.contentDidAppear(in: CEFTabContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(tab.state.processExit != nil, "a crash the user saw stays until Reload")
    }

    /// chrome://crash never commits: Reload must reload the committed page,
    /// not load chrome://crash into a renderer-less tab, which
    /// left it loading forever over Chromium's own Aw, Snap! page.
    @Test func reloadAfterADebugURLCrashReloadsTheCommittedPage() {
        let tab = makeTab()
        tab.load(a)
        tab.handle(.loadStart(browser: 1, url: a.absoluteString))
        tab.handle(.loadingState(browser: 1, loading: false, canGoBack: false, canGoForward: false))
        tab.load(URL(string: "chrome://crash")!)
        tab.handle(.renderTerminated(browser: 1, status: 2, code: 11, text: ""))
        #expect(tab.reloadPlan == .reloadEntry)
    }

    @Test func reloadAfterACrashBeforeAnyCommitLoadsTheURL() {
        let tab = makeTab()
        tab.load(a)
        tab.handle(.renderTerminated(browser: 1, status: 2, code: 11, text: ""))
        #expect(tab.reloadPlan == .load(a))
    }
}
