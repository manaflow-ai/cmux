import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextTestSupport
import Foundation
import Testing

/// "why are tabs crashing ugh" (user, 2026-10-30, NIGHTLY): with the Mac out of memory (swap
/// 15.5 of 16 GB, load ~300) WebKit's GPU process stopped answering again and again, WebKit ended
/// every web content process (`GPUProcessCrashedTooManyTimes`), and every tab showed "This page
/// crashed" until it was reloaded by hand. A page the system ended for memory reloads by itself,
/// once, when it is shown; a crash with memory to spare still waits for Reload.
@Suite(.closesItsWindows) struct BrowserExitRecoveryPolicyTests {
    private let start = ContinuousClock.now

    @Test(arguments: [MemoryPressureLevel.normal, .warning, .critical])
    func outOfMemoryAlwaysReloads(pressure: MemoryPressureLevel) {
        var recovery = BrowserExitRecovery()
        let owed = recovery.processEnded(BrowserProcessExit(reason: .outOfMemory), pressure: pressure, now: start)
        let first = recovery.takeReload(now: start)
        let second = recovery.takeReload(now: start)
        #expect(owed)
        #expect(first)
        #expect(!second, "it reloads once")
    }

    @Test(arguments: [BrowserProcessExit.Reason.crashed, .killed, .abnormal])
    func anEndUnderPressureReloads(reason: BrowserProcessExit.Reason) {
        var recovery = BrowserExitRecovery()
        let owed = recovery.processEnded(BrowserProcessExit(reason: reason), pressure: .warning, now: start)
        #expect(owed)
    }

    @Test(arguments: [BrowserProcessExit.Reason.crashed, .killed, .abnormal, .launchFailed, .integrityFailure])
    func anEndWithMemoryToSpareWaitsForThePerson(reason: BrowserProcessExit.Reason) {
        var recovery = BrowserExitRecovery()
        let owed = recovery.processEnded(BrowserProcessExit(reason: reason), pressure: .normal, now: start)
        let reloads = recovery.takeReload(now: start)
        #expect(!owed)
        #expect(!reloads)
    }

    @Test func aSecondMemoryEndSoonAfterWaitsForThePerson() {
        var recovery = BrowserExitRecovery(window: .seconds(600))
        recovery.processEnded(BrowserProcessExit(reason: .outOfMemory), pressure: .critical, now: start)
        let first = recovery.takeReload(now: start)
        let soon = recovery.processEnded(BrowserProcessExit(reason: .outOfMemory), pressure: .critical, now: start + .seconds(60))
        let later = recovery.processEnded(BrowserProcessExit(reason: .outOfMemory), pressure: .critical, now: start + .seconds(601))
        #expect(first)
        #expect(!soon, "a page that keeps dying would reload in a loop")
        #expect(later)
    }

    @Test func thePersonsReloadCancelsTheOwedOne() {
        var recovery = BrowserExitRecovery()
        recovery.processEnded(BrowserProcessExit(reason: .outOfMemory), pressure: .critical, now: start)
        recovery.cancel()
        let reloads = recovery.takeReload(now: start)
        #expect(!reloads)
    }

    @Test func theKernelLevelMaps() {
        #expect(KernelMemoryPressureLevel.level(kernel: 1) == .normal)
        #expect(KernelMemoryPressureLevel.level(kernel: 2) == .warning)
        #expect(KernelMemoryPressureLevel.level(kernel: 4) == .critical)
        #expect(KernelMemoryPressureLevel.level(kernel: 0) == .normal)
    }
}

/// The same through a real WebKit tab: its web content process ends (WebKit's delegate callback,
/// as WebKit sends it) and the tab reloads by itself, or shows the crash page, by memory pressure.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1))) struct WebKitTabExitRecoveryTests {
    final class Page {
        let window: NSWindow
        let tab: WebKitTab

        init(onScreen: Bool, pressure: MemoryPressureLevel) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            tab = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            tab.memoryPressure = { pressure }
            if onScreen {
                tab.contentView.frame = window.contentLayoutRect
                window.contentView = tab.contentView
                window.orderFrontRegardless()
            }
        }

        func load() async throws {
            tab.load(try #require(URL(string: "data:text/html,<p>page</p>")))
            try await until("the page loaded") { self.tab.state.hasEndedLoad && !self.tab.state.isLoading }
        }

        func until(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    Issue.record("timed out: \(what)")
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func close() {
            window.orderOut(nil)
            window.close()
            tab.close()
        }
    }

    @Test func aPageOnScreenEndedForMemoryReloadsAtOnce() async throws {
        let page = Page(onScreen: true, pressure: .critical)
        defer { page.close() }
        try await page.load()
        page.tab.webViewWebContentProcessDidTerminate(page.tab.webView)
        try await page.until("the page reloaded") { page.tab.state.processExit == nil }
        #expect(page.tab.state.processExit == nil, "the crash page stayed after a memory end")
    }

    @Test func aHiddenPageEndedForMemoryReloadsWhenShown() async throws {
        let page = Page(onScreen: false, pressure: .warning)
        defer { page.close() }
        try await page.load()
        page.tab.webViewWebContentProcessDidTerminate(page.tab.webView)
        #expect(page.tab.state.processExit != nil, "a hidden page reloaded while memory was short")
        page.tab.setContentVisible(true)
        try await page.until("the page reloaded when shown") { page.tab.state.processExit == nil }
        #expect(page.tab.state.processExit == nil)
    }

    @Test func aCrashWithMemoryToSpareWaitsForReload() async throws {
        let page = Page(onScreen: true, pressure: .normal)
        defer { page.close() }
        try await page.load()
        page.tab.webViewWebContentProcessDidTerminate(page.tab.webView)
        page.tab.setContentVisible(true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(page.tab.state.processExit?.reason == .crashed)
    }

    @Test func aSecondMemoryEndShowsTheCrashPage() async throws {
        let page = Page(onScreen: true, pressure: .critical)
        defer { page.close() }
        try await page.load()
        page.tab.webViewWebContentProcessDidTerminate(page.tab.webView)
        try await page.until("the page reloaded") { page.tab.state.processExit == nil }
        try await page.until("the reload finished") { !page.tab.state.isLoading }
        page.tab.webViewWebContentProcessDidTerminate(page.tab.webView)
        try await Task.sleep(for: .milliseconds(500))
        #expect(page.tab.state.processExit != nil, "a page that keeps dying reloaded again")
    }
}
