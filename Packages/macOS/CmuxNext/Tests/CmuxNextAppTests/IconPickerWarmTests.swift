import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextPages
import Testing
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The icon picker is warm before its first open (cx-ag5.9.2): the app prepares its panel, page
/// and symbol catalog at an idle moment after launch, so the first Set Icon opens as fast as later
/// ones instead of loading the catalog and a cold page first.
@MainActor
struct IconPickerWarmTests {
    @Test func preparingMakesThePickerWarmBeforeAnyOpen() async {
        let host = WebUIHost.iconPickerTestHost()
        let picker = IconPickerService(services: nil, webUI: host, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        #expect(!picker.isWarm)
        #expect(host.openPages.isEmpty)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            picker.prepare { done.resume() }
        }
        #expect(picker.isWarm)
        // The warm page is opened through the injected host, not around it.
        #expect(host.openPages.count == 1)
    }

    /// Two prepares while the catalog loads share one load: each runs once it is in, as its own
    /// posted task, and the picker makes one warm page.
    @Test func preparesDuringTheCatalogLoadShareItAndEachRuns() async {
        let host = WebUIHost.iconPickerTestHost()
        let picker = IconPickerService(services: nil, webUI: host, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var ran = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finished = { ran += 1; if ran == 2 { done.resume() } }
            picker.prepare(then: finished)
            picker.prepare(then: finished)
        }
        #expect(ran == 2)
        #expect(picker.isWarm)
        #expect(host.openPages.count == 1)
    }

    /// A pick that arrives while the launch-idle prepare's catalog load runs opens as the person's work:
    /// its reply is userBlocking, not the prepare's background class, so a launch that
    /// still holds background work does not hold the open.
    @Test(.timeLimit(.minutes(1))) func aPickDuringTheBackgroundPrepareOpensWhileBackgroundIsHeld() async {
        // A launch that never reveals: background tasks stay held for the whole test.
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let mainWork = MainWorkScheduler(budget: MainFrameBudget(), startup: startup)
        let picker = IconPickerService(services: nil, webUI: .iconPickerTestHost(), mainWork: mainWork)
        var prepared = false
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            picker.onOpened = { [weak picker] _ in
                picker?.onOpened = nil
                done.resume()
            }
            picker.prepare { prepared = true }
            picker.pick(current: nil, target: "workspace:1", at: Self.anchor) { _ in }
        }
        #expect(picker.open?.target == "workspace:1")
        #expect(!prepared, "the prepare's own reply is background work, still held by the launch")
    }

    /// An anchor in no window: the picker opens without showing its panel.
    private static let anchor = IconPickerService.Anchor(view: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)),
                                                         rect: NSRect(x: 10, y: 10, width: 2, height: 2))
}

extension WebUIHost {
    /// A page host with no Chromium host and no open panel, so the picker's page is WebKit.
    static func iconPickerTestHost() -> WebUIHost {
        WebUIHost(chromium: nil, openPanel: nil, memory: ManualMemoryLevelRegistry(), deadlines: .testing())
    }
}
