import AppKit
@testable import CmuxNextApp
import CmuxNextLaunch
import CmuxNextWakeupsTestSupport
import Testing

/// Home and the New Tab page's feeds at launch (p08-startup-027): the launch posts them after
/// startup; a Home view or an agent page that shows moves them to right after the first frame. No
/// Chief owner, chats feed or Cloud read starts before the first frame, and a Home view still draws
/// the last launch's list from its cache (HomeLaunchListTests).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeFeedsAfterFirstFrameTests {
    @Test func aHomeViewMovesTheFeedsToRightAfterTheFirstFrame() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let s = StartupTestScheduler(), runs = Runs()
        let feeds = LaunchNeedPosts(startup: s.startup, starts: [.init("Home.start") { runs.count += 1 }])
        services.home.launchFeeds = feeds
        feeds.post()
        let page = TopHomePageView(services: services, windowKey: { "feeds-after-first-frame" })
        #expect(feeds.isNeeded, "a Home view needs Home")
        s.fire()
        #expect(runs.count == 0, "no Chief owner or Cloud start before the first frame")
        #expect(!services.home.chief.isRunning, "the view's own build started no Chief owner")
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(runs.count == 1, "Home starts right after the first frame")
        #expect(s.startup.completion == nil, "without waiting for startup to complete")
        _ = page
    }

    @Test func anAgentPageMovesTheFeedsToRightAfterTheFirstFrame() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let s = StartupTestScheduler(), runs = Runs()
        let feeds = LaunchNeedPosts(startup: s.startup, starts: [.init("NewTabWeather.wire") { runs.count += 1 }])
        services.home.launchFeeds = feeds
        feeds.post()
        services.agentTabs.pageShown()
        #expect(feeds.isNeeded, "the agent tab store's page hook is wired to the launch's feeds")
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(runs.count == 1)
    }

    @Test func withNoPageTheFeedsWaitForStartup() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let s = StartupTestScheduler(), runs = Runs()
        let feeds = LaunchNeedPosts(startup: s.startup, starts: [.init("Home.start") { runs.count += 1 }])
        services.home.launchFeeds = feeds
        feeds.post()
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(runs.count == 0, "a launch with no Home or agent page keeps them out of the first frames")
        s.startup.finishRegistration()
        s.hand.drain()
        s.fire()
        #expect(runs.count == 1)
    }
}

@MainActor
private final class Runs {
    var count = 0
}
