import AppKit
import CmuxNextDaemon
import CmuxNextWakeups
import Testing
@testable import CmuxNextApp

/// AppServices never reads the global `NSApp` for the key window or whether the app is active: `NSApp`
/// is `NSApplication!`, nil in a test process that never made `NSApplication.shared`, and its implicit
/// unwrap ended the whole test process (and hid every later test) as soon as a test reached a lookup.
///
/// The fleet runs a suite alone in its own process (`swift test --filter`), where nothing makes the
/// application object, so a lookup that still reads `NSApp` traps here.
@MainActor
@Suite(.serialized)
struct AppServicesKeyWindowSourceTests {
    /// The lookups the quit's sheet (`QuitCoordinator.sheetWindow`), the action handlers
    /// (`windows.active`), the key routing (`keyWindowRole`) and the notifications (`viewedTabs`,
    /// `isViewed`) make, with the services every test builds. Only that they return is checked: on a GUI
    /// lane an earlier test can leave a real key window and an active app, which these may report.
    @Test func keyWindowLookupsWithNoApplicationObjectDoNotTrap() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        _ = services.keyWindowSource()
        _ = services.windows.active
        _ = services.keyWindowRole
        _ = services.notifications.viewedTabs(services.daemon.store)
        _ = services.notifications.isViewed("no-such-tab")
    }

    /// The same checks when an earlier test in this process already made `NSApplication.shared` (then
    /// `NSApp` is set and the trap cannot show): every key-window and app-active lookup asks the source
    /// the composition root passed, never the global application, and so do the tasks AppServices starts
    /// (the notifications' viewed-program-status observation, the first trap's path in #28275's quit tests).
    /// No clock decides: the started task's first pass is awaited as the next ask of the source.
    @Test func everyLookupAndTheStartedTasksAskTheInjectedSources() async {
        let asks = SourceAsks()
        let services = AppServices(environment: AppEnvironment.current([:]), keyWindowSource: { asks.keyWindow += 1; return nil },
                                   appActiveSource: { asks.appActiveAsked(); return false }, heldKeyReplay: { _, _, _ in })
        let windows = services.windows
        var before = asks.keyWindow
        #expect(windows.active == nil)
        #expect(asks.keyWindow == before + 1, "windows.active did not ask the injected key-window source")
        before = asks.keyWindow
        #expect(services.keyWindowRole == nil)
        #expect(asks.keyWindow == before + 1, "keyWindowRole did not ask the injected key-window source")
        // No started task has run yet: this test holds the main actor until its first await.
        let activeBefore = asks.appActive
        #expect(services.notifications.viewedTabs(services.daemon.store).isEmpty)
        #expect(!services.notifications.isViewed("no-such-tab"))
        guard asks.appActive == activeBefore + 2 else {
            Issue.record("the notifications' viewed-tab lookups did not ask the injected app-active source")
            return  // the started task would never ask it either: fail here, never wait for it
        }
        await asks.nextAppActiveAsk()
    }
}

/// How many times each source was asked, and a wait for the next app-active ask.
@MainActor
private final class SourceAsks {
    var keyWindow = 0
    private(set) var appActive = 0
    private var awaitedAfter = Int.max
    private let next = FirstOutcome<Void>()

    func appActiveAsked() {
        appActive += 1
        if appActive > awaitedAfter { next.resolve(()) }
    }

    func nextAppActiveAsk() async {
        awaitedAfter = appActive
        await next.value()
    }
}
