import Foundation
import Testing

@testable import CmuxBrowser

/// A deadline that has already passed.
private struct ElapsedSleeper: BrowserReplSleeping {
    func sleep(for duration: Duration) async throws {}
}

/// A deadline that never passes during a test (cancelled with its race).
private struct DistantSleeper: BrowserReplSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

/// A tab whose web content the test changes, standing in for a browser pane.
@MainActor
private final class FakeTab {
    var condition: BrowserReplTabCondition
    var wakeCount = 0
    /// What a wake does to the tab: by default a restore starts.
    var onWake: (FakeTab) -> Void = { $0.condition.isWaking = true }
    /// What waiting for the load does: by default the restore commits.
    var onWait: (FakeTab) async -> Void = { $0.condition = BrowserReplTabCondition() }

    init(_ condition: BrowserReplTabCondition) {
        self.condition = condition
    }

    func prepare(_ method: String, sleeper: any BrowserReplSleeping) async throws {
        let waker = BrowserReplTabWaker(sleeper: sleeper, timeout: .seconds(30))
        try await waker.prepare(
            method: method,
            tab: BrowserReplTabLabel(id: "T1", title: "Inbox", url: "https://mail.example.com/"),
            condition: { self.condition },
            wake: {
                self.wakeCount += 1
                self.onWake(self)
            },
            waitUntilLoaded: { await self.onWait(self) }
        )
    }
}

@MainActor
@Suite("Browser REPL hibernated and crashed tabs")
struct BrowserReplTabWakeTests {
    private func driverError(_ body: () async throws -> Void) async -> BrowserReplDriverError? {
        do {
            try await body()
            return nil
        } catch let error as BrowserReplDriverError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test func statesNameWhatTheAgentSees() {
        #expect(BrowserReplTabCondition().state == .live)
        #expect(BrowserReplTabCondition(isHibernated: true).state == .hibernated)
        #expect(BrowserReplTabCondition(isHibernated: true, isWaking: true).state == .waking)
        #expect(BrowserReplTabCondition(isCrashed: true).state == .crashed)
        #expect(BrowserReplTabCondition(isHibernated: true, isCrashed: true).state == .crashed)
    }

    @Test func aLiveTabRunsTheCallAtOnce() async throws {
        let tab = FakeTab(BrowserReplTabCondition())
        try await tab.prepare("frame.evaluate", sleeper: DistantSleeper())
        #expect(tab.wakeCount == 0)
    }

    @Test func aHibernatedTabIsWokenAndTheCallWaitsForItsPage() async throws {
        let tab = FakeTab(BrowserReplTabCondition(isHibernated: true))
        try await tab.prepare("frame.evaluate", sleeper: DistantSleeper())
        #expect(tab.wakeCount == 1)
        #expect(tab.condition.state == .live)
    }

    @Test func aTabAlreadyWakingIsWaitedFor() async throws {
        let tab = FakeTab(BrowserReplTabCondition(isHibernated: true, isWaking: true))
        try await tab.prepare("input.mouse", sleeper: DistantSleeper())
        #expect(tab.condition.state == .live)
    }

    @Test func aWakeThatOutlastsItsBoundFailsWithATimeoutThatNamesTheTab() async {
        let tab = FakeTab(BrowserReplTabCondition(isHibernated: true))
        tab.onWait = { _ in try? await Task.sleep(for: .seconds(3600)) }
        let error = await driverError { try await tab.prepare("frame.evaluate", sleeper: ElapsedSleeper()) }
        #expect(error?.code == "timeout")
        #expect(error?.message.contains("tab T1 (\"Inbox\", https://mail.example.com/)") == true)
        #expect(error?.message.contains("hibernated") == true)
        #expect(error?.message.contains("30 s") == true)
        #expect(error?.message.contains("retry") == true)
    }

    @Test func aRestoreTheUserStoppedFailsAtOnceWithWhatToDo() async {
        let tab = FakeTab(BrowserReplTabCondition(isHibernated: true, restoreStoppedByUser: true))
        // Stopped: the wake starts no restore, so nothing is waited for.
        tab.onWake = { _ in }
        tab.onWait = { _ in Issue.record("waited for a restore that never started") }
        let error = await browserReplWithDeadline(seconds: 10) { @MainActor in
            await driverError { try await tab.prepare("frame.evaluate", sleeper: DistantSleeper()) }
        }
        let thrown = error ?? nil
        #expect(thrown?.code == "hibernated")
        #expect(thrown?.message.contains("stopped") == true)
        #expect(thrown?.message.contains("page.reload()") == true)
    }

    @Test func aRestoreThatEndsWithoutAPageFailsWithWhatToDo() async {
        let tab = FakeTab(BrowserReplTabCondition(isHibernated: true))
        // The restore navigation failed: the tab is still unloaded and no load runs.
        tab.onWait = { $0.condition = BrowserReplTabCondition(isHibernated: true) }
        let error = await driverError { try await tab.prepare("tab.screenshot", sleeper: DistantSleeper()) }
        #expect(error?.code == "hibernated")
        #expect(error?.message.contains("page.reload()") == true)
    }

    @Test func aCrashedTabFailsWithReloadAdvice() async {
        let tab = FakeTab(BrowserReplTabCondition(isCrashed: true))
        let error = await driverError { try await tab.prepare("input.key", sleeper: DistantSleeper()) }
        #expect(error?.code == "crashed")
        #expect(error?.message.contains("tab T1") == true)
        #expect(error?.message.contains("page.reload()") == true)
        #expect(tab.wakeCount == 0)
    }

    @Test func aCrashedTabStillAnswersNavigationAndInfo() async throws {
        for method in ["tab.reload", "tab.navigate", "tab.history", "tab.info", "tabs.close", "tab.bringToFront"] {
            let tab = FakeTab(BrowserReplTabCondition(isCrashed: true))
            try await tab.prepare(method, sleeper: DistantSleeper())
        }
    }

    @Test func aWakeThatEndsInACrashSaysSo() async {
        let tab = FakeTab(BrowserReplTabCondition(isHibernated: true))
        tab.onWait = { $0.condition = BrowserReplTabCondition(isCrashed: true) }
        let error = await driverError { try await tab.prepare("frame.evaluate", sleeper: DistantSleeper()) }
        #expect(error?.code == "crashed")
    }

    @Test func closingKeepingOrNavigatingAHibernatedTabDoesNotWaitForItsOldPage() async throws {
        for method in ["tabs.close", "tab.keep", "tab.navigate", "tab.reload", "tab.history"] {
            let tab = FakeTab(BrowserReplTabCondition(isHibernated: true))
            tab.onWait = { _ in Issue.record("\(method) waited for the old page") }
            try await tab.prepare(method, sleeper: DistantSleeper())
            #expect(tab.condition.state == .hibernated)
        }
    }

    @Test func aTabWithNoTitleIsNamedByItsURL() {
        #expect(BrowserReplTabLabel(id: "T2", title: "", url: "https://x.example/").description == "tab T2 (https://x.example/)")
        #expect(BrowserReplTabLabel(id: "T3", title: "", url: "").description == "tab T3")
    }
}
