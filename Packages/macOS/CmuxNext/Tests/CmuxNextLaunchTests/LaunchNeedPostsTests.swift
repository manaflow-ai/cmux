import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Home and the New Tab page's feeds at launch (p08-startup task 027): never before the first frame;
/// after startup by default; right after the first frame, or in the next frames once it passed, when a
/// Home or agent page shows. Each start runs once and in its own post.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchNeedPostsTests {
    private static func feeds(_ s: StartupTestScheduler, _ runs: RunLog) -> LaunchNeedPosts {
        LaunchNeedPosts(startup: s.startup, starts: [
            .init("Home.start", needed: "Home.startNeeded") { runs.names.append("Home.start") },
            .init("ChatsFeed.keepCurrent", needed: "ChatsFeed.keepCurrentNeeded") { runs.names.append("ChatsFeed.keepCurrent") },
            .init("NewTabWeather.wire", needed: "NewTabWeather.wireNeeded") { runs.names.append("NewTabWeather.wire") },
        ])
    }

    @Test func aPageShownBeforeTheFirstFrameStartsTheFeedsRightAfterIt() {
        let s = StartupTestScheduler(), runs = RunLog()
        let feeds = Self.feeds(s, runs)
        feeds.post()
        feeds.need()
        s.fire()
        #expect(runs.names.isEmpty, "no Chief, feed or cloud start before the first frame")
        s.startup.firstFrameCommitted()
        for _ in 0..<6 { s.fire() }
        #expect(runs.names == ["Home.start", "ChatsFeed.keepCurrent", "NewTabWeather.wire"], "in order, right after the first frame")
        #expect(s.startup.completion == nil, "they did not wait for startup to complete")
        #expect(feeds.started == runs.names)
    }

    /// The restore makes its saved windows after the first frame: a Home page made then starts the
    /// feeds in the next frames, never at the end of startup (which that page holds open).
    @Test func aPageShownAfterTheFirstFrameStartsTheFeedsInTheNextFrames() {
        let s = StartupTestScheduler(), runs = RunLog()
        let feeds = Self.feeds(s, runs)
        feeds.post()
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(runs.names.isEmpty, "no page needs them yet")
        feeds.need()
        for _ in 0..<6 { s.fire() }
        #expect(runs.names.count == 3)
        #expect(s.startup.completion == nil, "before startup completes")
        feeds.need()
        for _ in 0..<3 { s.fire() }
        #expect(runs.names.count == 3, "one need per launch")
    }

    @Test func withNoPageTheFeedsStartAfterStartupEachOnce() {
        let s = StartupTestScheduler(), runs = RunLog()
        Self.feeds(s, runs).post()
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(runs.names.isEmpty, "a launch with no Home or agent page keeps them out of the first frames")
        s.startup.finishRegistration()
        s.hand.drain()
        #expect(s.startup.completion != nil)
        for _ in 0..<6 { s.fire() }
        #expect(runs.names == ["Home.start", "ChatsFeed.keepCurrent", "NewTabWeather.wire"])
    }

    /// A need after some afterStartup posts ran reposts only the rest; nothing runs twice.
    @Test func aNeedAfterStartupCompletedRunsNothingTwice() {
        let s = StartupTestScheduler(), runs = RunLog()
        let feeds = Self.feeds(s, runs)
        feeds.post()
        s.complete()
        s.fire()
        #expect(runs.names == ["Home.start"], "one afterStartup post per frame")
        feeds.need()
        for _ in 0..<6 { s.fire() }
        #expect(runs.names == ["Home.start", "ChatsFeed.keepCurrent", "NewTabWeather.wire"], "each start once")
    }

    /// A page that needed the feeds leaves one afterStartup post queued, not one per start: the
    /// after-startup work behind it waits one empty frame at most, and the records name the path
    /// that ran each start once (Chrome's AfterStartupTaskUtils runs no phantom duplicates).
    @Test func aNeedLeavesOneQueuedPostAndNamesItsRuns() {
        let s = StartupTestScheduler(), runs = RunLog()
        let feeds = Self.feeds(s, runs)
        feeds.post()
        feeds.post()
        feeds.need()
        s.startup.firstFrameCommitted()
        for _ in 0..<6 { s.fire() }
        #expect(runs.names.count == 3)
        s.complete()
        #expect(s.startup.completion?.heldTasks == 1, "one afterStartup post, not one per start")
        for _ in 0..<6 { s.fire() }
        #expect(runs.names.count == 3, "the queued post runs nothing twice and posts no more")
        let names = s.startup.log.records.map(\.name.description)
        #expect(names == ["Home.start", "Home.startNeeded", "ChatsFeed.keepCurrentNeeded", "NewTabWeather.wireNeeded"])
    }

    /// Without a page the one queued post runs its start, then posts the next: one start per frame.
    @Test func withNoPageEachStartIsItsOwnFrame() {
        let s = StartupTestScheduler(), runs = RunLog()
        Self.feeds(s, runs).post()
        s.complete()
        #expect(s.startup.completion?.heldTasks == 1)
        #expect(s.startup.log.records.map(\.name.description) == ["Home.start"])
        s.fire()
        #expect(runs.names == ["Home.start"], "one start per frame")
        s.fire()
        #expect(runs.names == ["Home.start", "ChatsFeed.keepCurrent"])
        for _ in 0..<6 { s.fire() }
        #expect(runs.names == ["Home.start", "ChatsFeed.keepCurrent", "NewTabWeather.wire"])
    }

    @Test func quitNeverStartsTheFeeds() {
        let s = StartupTestScheduler(), runs = RunLog()
        let feeds = Self.feeds(s, runs)
        feeds.post()
        s.startup.beginQuit()
        feeds.need()
        s.complete()
        for _ in 0..<6 { s.fire() }
        #expect(runs.names.isEmpty)
    }
}

@MainActor
private final class RunLog {
    var names: [String] = []
}
