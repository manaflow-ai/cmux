import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLaunch
@testable import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The app's launch starts by class (p06-scheduler-049) through `AppServices`: bookmark sync,
/// closed-history retention and the Chromium likelihood hint each run at once and post nothing. A first-frame start is the current task in the launch turn, never a post. A
/// Mac Screen tab or Settings > Devices posts the device hub's start right after the first frame, once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct LaunchStartWiringTests {
    /// Services on a test launch scheduler that never completes.
    private static func services() -> (AppServices, StartupTestScheduler) {
        _ = NSApplication.shared
        let s = StartupTestScheduler(phase: StartupPhase(clock: ManualClock(), ledger: WakeupLedger()))
        let services = AppServices(environment: AppEnvironment.current([:]), launchStartup: s.startup)
        return (services, s)
    }

    private static func settings(_ services: AppServices) -> SettingsController {
        let url = FileManager.default.temporaryDirectory.appending(path: "cnc-launch-start-\(UUID().uuidString)/cmux.json")
        return SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                  managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
    }

    private static func posted(_ s: StartupTestScheduler) -> [String] {
        s.hand.drain()
        return s.startup.log.records.map(\.name.description)
    }

    @Test func theAfterRevealStartsRunAtOnceAndPostNothing() {
        let (services, s) = Self.services()
        defer {
            s.startup.beginQuit()
            services.chromiumLikelyObservations.forEach { $0.cancel() }
        }
        let settings = Self.settings(services)
        services.bookmarks.startSync()
        services.history.startDaemonSync(settings: settings)
        services.postChromiumLikely()
        #expect(Self.posted(s).isEmpty)
        #expect(services.bookmarks.chromium != nil, "the sync started where it started before")
        #expect(services.chromiumLikelyObservations.count == 1, "the tab walk started where it started before")
    }

    @Test func aFirstFrameStartRunsNowAsTheCurrentTask() {
        let (services, s) = Self.services()
        let current = CurrentTask()
        services.runLaunchStart(.energy) { [s] in current.name = s.startup.log.currentMainTask }
        #expect(current.name == "AppServices.startEnergy")
        #expect(Self.posted(s).isEmpty, "a first-frame start is never a post")
        s.startup.beginQuit()
    }

    @Test func aVisibleNeedPostsTheDeviceHubRightAfterTheFirstFrameOnce() {
        let (services, s) = Self.services()
        defer { s.startup.beginQuit() }
        services.macScreenTabs.hubNeeded()
        #expect(Self.posted(s).isEmpty, "no settings yet: nothing to start the hub with")
        services.settings = Self.settings(services)
        services.macScreenTabs.hubNeeded()
        services.macScreenTabs.hubNeeded()
        #expect(Self.posted(s) == ["DeviceHub.startNeeded"])
        #expect(s.startup.log.records.first?.priority == .afterFirstFrame)
    }
}

/// The watchdog's current task as a start saw it.
@MainActor
private final class CurrentTask {
    var name: String?
}
