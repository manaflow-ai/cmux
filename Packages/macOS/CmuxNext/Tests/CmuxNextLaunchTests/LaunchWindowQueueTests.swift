import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreGraphics
import Testing

/// The restored windows behind the front one at launch: visibility is by occlusion
/// and display, not z-order; a window that shows is built in its own afterFirstFrame post, one per
/// post; a covered, off-screen or full-screen one only after startup completes, or at once when taken.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchWindowQueueTests {
    private static let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    // MARK: Visibility

    @Test func aWindowContainedByOneInFrontIsHiddenAndAPartlyCoveredOneShows() {
        let visibility = LaunchWindowVisibility(screens: [Self.display])
        let split = visibility.split([
            .init(id: "front", frame: CGRect(x: 0, y: 0, width: 1200, height: 900)),
            .init(id: "covered", frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
            .init(id: "beside", frame: CGRect(x: 1000, y: 100, width: 800, height: 600)),
        ], built: ["front"])
        #expect(split == .init(visible: ["beside"], hidden: ["covered"]),
                "a window in front that contains the frame covers it; one that only overlaps it does not")
    }

    @Test func twoWindowsThatTogetherCoverAThirdDoNotHideIt() {
        let visibility = LaunchWindowVisibility(screens: [Self.display])
        let split = visibility.split([
            .init(id: "left", frame: CGRect(x: 0, y: 0, width: 960, height: 1080)),
            .init(id: "right", frame: CGRect(x: 960, y: 0, width: 960, height: 1080)),
            .init(id: "under", frame: CGRect(x: 400, y: 200, width: 1000, height: 600)),
        ], built: ["left"])
        #expect(split.visible == ["right", "under"], "no region union, as Chrome's checker: rounded corners can show it")
    }

    @Test func aWindowOnAnotherDisplayShowsAndOneOnNoDisplayIsHidden() {
        let visibility = LaunchWindowVisibility(screens: [Self.display, Self.second])
        let split = visibility.split([
            .init(id: "front", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            .init(id: "other-display", frame: CGRect(x: 2000, y: 100, width: 800, height: 600)),
            .init(id: "nowhere", frame: CGRect(x: 9000, y: 9000, width: 800, height: 600)),
        ], built: ["front"])
        #expect(split == .init(visible: ["other-display"], hidden: ["nowhere"]))
    }

    @Test func aFullScreenWindowIsHiddenAndCoversNothing() {
        let visibility = LaunchWindowVisibility(screens: [Self.display])
        let split = visibility.split([
            .init(id: "front", frame: CGRect(x: 0, y: 0, width: 600, height: 400)),
            .init(id: "full-screen", frame: Self.display, onActiveSpace: false),
            .init(id: "under", frame: CGRect(x: 700, y: 100, width: 600, height: 400)),
        ], built: ["front"])
        #expect(split == .init(visible: ["under"], hidden: ["full-screen"]), "its own Space: it shows nothing here and hides nothing")
    }

    @Test func aWindowWithNoFrameShowsAndAHiddenAppShowsNothing() {
        let saved: [LaunchWindowVisibility.Saved] = [.init(id: "front", frame: Self.display), .init(id: "unplaced", frame: nil)]
        #expect(LaunchWindowVisibility(screens: [Self.display]).split(saved, built: ["front"]).visible == ["unplaced"])
        let hidden = LaunchWindowVisibility(screens: [Self.display], rule: WindowOcclusionRule(appHidden: true))
        #expect(hidden.split(saved, built: ["front"]) == .init(visible: [], hidden: ["unplaced"]))
    }

    // MARK: Queue

    /// Acceptance: with 3 windows, 1 of them occluded, only the visible ones build before completion.
    @Test func threeWindowsOneOccludedOnlyTheVisibleOnesBuildBeforeCompletion() {
        let s = StartupTestScheduler(), windows = BuiltWindows(startup: s.startup)
        let split = LaunchWindowVisibility(screens: [Self.display]).split([
            .init(id: "front", frame: CGRect(x: 0, y: 0, width: 1200, height: 900)),
            .init(id: "visible", frame: CGRect(x: 1000, y: 100, width: 800, height: 600)),
            .init(id: "occluded", frame: CGRect(x: 100, y: 100, width: 600, height: 400)),
        ], built: ["front"])
        #expect(windows.queue.schedule(split))
        for _ in 0..<3 { s.fire() }
        #expect(windows.built.isEmpty, "nothing builds before the first frame")
        #expect(windows.queue.waitingVisible == ["visible"])
        s.startup.finishRegistration()
        s.startup.firstFrameCommitted()
        for _ in 0..<4 { s.fire() }
        #expect(windows.built == ["visible"], "the window that shows builds in its afterFirstFrame post")
        #expect(s.startup.completion == nil)
        #expect(windows.queue.isWaiting("occluded"))
        s.hand.drain()
        #expect(s.startup.completion != nil)
        for _ in 0..<4 { s.fire() }
        #expect(windows.built == ["visible", "occluded"], "the covered window builds only after startup completes")
        let records = s.startup.log.records
        #expect(records.map(\.name.description) == ["WindowManager.buildVisibleWindow", "WindowManager.buildHiddenWindow"])
        #expect(records.map(\.priority) == [.afterFirstFrame, .afterStartup])
        #expect(records.allSatisfy { $0.destination == .main })
    }

    @Test func visibleWindowsBuildOnePerPostFrontFirst() {
        let s = StartupTestScheduler(), windows = BuiltWindows(startup: s.startup)
        #expect(windows.queue.schedule(.init(visible: ["a", "b", "c"])))
        #expect(s.startup.log.records.count == 3, "one post per window: no main turn builds them all")
        s.startup.firstFrameCommitted()
        for _ in 0..<8 { s.fire() }
        #expect(windows.built == ["a", "b", "c"], "front first")
    }

    @Test func aTakenWindowIsBuiltByItsCallerAndNeverByAPost() {
        let s = StartupTestScheduler(), windows = BuiltWindows(startup: s.startup)
        windows.queue.schedule(.init(visible: ["a", "b"], hidden: ["c"]))
        #expect(windows.queue.take("a"))
        #expect(windows.queue.take("c"))
        #expect(!windows.queue.take("c"), "taken once")
        #expect(!windows.queue.isWaiting("a"))
        s.complete()
        for _ in 0..<8 { s.fire() }
        #expect(windows.built == ["b"], "the posts build only what still waits")
    }

    @Test func aClosedWindowIsNeverBuilt() {
        let s = StartupTestScheduler(), windows = BuiltWindows(startup: s.startup)
        windows.queue.schedule(.init(visible: ["a", "b"], hidden: ["c"]))
        windows.queue.keep(["b"])
        #expect(windows.queue.waitingVisible == ["b"])
        #expect(!windows.queue.isWaiting("c"))
        s.complete()
        for _ in 0..<8 { s.fire() }
        #expect(windows.built == ["b"])
    }

    @Test func aWindowWaitsOnce() {
        let s = StartupTestScheduler(), windows = BuiltWindows(startup: s.startup)
        windows.queue.schedule(.init(visible: ["a"]))
        windows.queue.schedule(.init(visible: ["a"], hidden: ["a"]))
        #expect(s.startup.log.records.count == 1)
        s.complete()
        for _ in 0..<4 { s.fire() }
        #expect(windows.built == ["a"])
    }

    @Test func quittingBuildsNothingAndRefusesNewWaits() {
        let s = StartupTestScheduler(), windows = BuiltWindows(startup: s.startup)
        windows.queue.schedule(.init(visible: ["a"], hidden: ["b"]))
        s.startup.beginQuit()
        s.complete()
        for _ in 0..<4 { s.fire() }
        #expect(windows.built.isEmpty)
        #expect(!windows.queue.schedule(.init(visible: ["c"])), "quitting: the caller builds")
    }

    @Test func afterCompletionTheWindowsStillBuildOnePerFrame() {
        let s = StartupTestScheduler(), windows = BuiltWindows(startup: s.startup)
        s.complete()
        #expect(windows.queue.schedule(.init(visible: ["a"], hidden: ["b", "c"])))
        #expect(windows.built.isEmpty, "never in the restore's own turn")
        for _ in 0..<8 { s.fire() }
        #expect(windows.built == ["a", "b", "c"])
    }
}

/// A queue and the windows it built, in order.
@MainActor
private final class BuiltWindows {
    let queue: LaunchWindowQueue
    private let log: BuildLog

    var built: [String] { log.ids }

    init(startup: StartupScheduler) {
        let log = BuildLog()
        self.log = log
        queue = LaunchWindowQueue(startup: startup) { id in log.ids.append(id) }
    }
}

@MainActor
private final class BuildLog {
    var ids: [String] = []
}
