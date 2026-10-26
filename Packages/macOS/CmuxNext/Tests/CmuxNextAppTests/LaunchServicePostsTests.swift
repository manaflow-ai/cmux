import CmuxNextLaunch
import CmuxNextWakeups
import Testing

/// The launch work no first frame needs (p08-startup-017): one StartupScheduler post per service at
/// its stated priority, and the agent pages' WebKit warm-up posted once, at afterFirstFrame only when
/// the restore shows a visible WebKit agent chat.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchServicePostsTests {
    @Test func eachServiceIsItsOwnPostAtItsPriority() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        LaunchServicePosts.nonPaint(
            freeTierAttest: { ran.names.append("FreeTierAttest.start") },
            ssh: { ran.names.append("SSH.start") },
            serverReach: { ran.names.append("ServerReach.start") },
            updater: { ran.names.append("Updater.start") },
            emptyWorkspaceRepair: { ran.names.append("EmptyWorkspaceRepair.observe") }
        ).post(on: f.order.startup)
        LaunchServicePosts.laterTabs(
            chromiumWarmup: { ran.names.append("ChromiumWarmup.start") },
            spareHooks: { ran.names.append("NewTabSpares.hooks") },
            spareWarming: { ran.names.append("NewTabSpares.warm") },
            pagePreload: { ran.names.append("PagePreload.start") },
            agentTabImport: { ran.names.append("AgentTabImport.start") },
            rightSidebarIcons: { ran.names.append("RightSidebar.prewarm") }
        ).post(on: f.order.startup)
        f.hand.drain()
        let posted = f.order.startup.log.records.map { ($0.name.description, $0.priority) }
        #expect(posted.map(\.0) == ["SSH.start", "FreeTierAttest.start", "ServerReach.start", "Updater.start",
                                    "EmptyWorkspaceRepair.observe", "ChromiumWarmup.start", "NewTabSpares.hooks",
                                    "NewTabSpares.warm", "PagePreload.start", "AgentTabImport.start", "RightSidebar.prewarm"])
        let firstFrame: Set<String> = ["SSH.start", "ChromiumWarmup.start", "NewTabSpares.hooks"]
        for (name, priority) in posted {
            #expect(priority == (firstFrame.contains(name) ? StartupPriority.afterFirstFrame : StartupPriority.afterStartup), "\(name)")
        }
        #expect(f.order.startup.log.records.allSatisfy { $0.destination == .main })
        f.order.startup.firstFrameCommitted()
        for _ in 0..<3 { f.fire() }
        #expect(ran.names == ["SSH.start", "ChromiumWarmup.start", "NewTabSpares.hooks"],
                "what the person sees soon runs after the first frame, before startup completes")
        f.complete()
        for _ in 0..<12 { f.fire() }
        #expect(ran.names == ["SSH.start", "ChromiumWarmup.start", "NewTabSpares.hooks", "FreeTierAttest.start",
                              "ServerReach.start", "Updater.start", "EmptyWorkspaceRepair.observe", "NewTabSpares.warm",
                              "PagePreload.start", "AgentTabImport.start", "RightSidebar.prewarm"],
                "each post ran its one service once, in post order within its priority")
        #expect(f.order.startup.log.records.allSatisfy { $0.durationNanos != nil }, "one record per task, each with its run")
    }

    /// p08-startup-031: the starts `AppServices.init` made before the first frame are posts: three after the
    /// first frame, three after startup, in post order with the launch's other afterStartup posts.
    @Test func initServiceStartsArePostsAtTheirDesignPriority() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        LaunchServicePosts.serviceStarts(
            windowOcclusion: { ran.names.append("SurfaceInvariant.observeWindowOcclusion") },
            inputVerification: { ran.names.append("InputVerification.start") },
            notifications: { ran.names.append("Notifications.start") },
            updaterWork: { ran.names.append("Updater.attachedWork") },
            serverUpdates: { ran.names.append("ServerUpdates.start") },
            browserHost: { ran.names.append("BrowserHost.start") }
        ).post(on: f.order.startup)
        LaunchServicePosts.nonPaint(
            freeTierAttest: {}, ssh: {}, serverReach: {}, updater: { ran.names.append("Updater.start") }, emptyWorkspaceRepair: {}
        ).post(on: f.order.startup)
        f.hand.drain()
        for _ in 0..<3 { f.fire() }
        #expect(ran.names.isEmpty, "nothing runs before the first frame")
        let firstFrame = ["SurfaceInvariant.observeWindowOcclusion", "InputVerification.start", "Notifications.start"]
        for record in f.order.startup.log.records where firstFrame.contains(record.name.description) {
            #expect(record.priority == .afterFirstFrame, "\(record.name)")
        }
        f.order.startup.firstFrameCommitted()
        for _ in 0..<4 { f.fire() }
        #expect(ran.names == firstFrame, "occlusion, input verification and banners run after the first frame, before completion")
        f.complete()
        for _ in 0..<12 { f.fire() }
        #expect(ran.names == firstFrame + ["Updater.attachedWork", "ServerUpdates.start", "BrowserHost.start", "Updater.start"],
                "the updater's reads, server updates and the browser host run after startup, in post order")
    }

    /// p08-startup-029: the platform services, one post each at their startup-DESIGN.md priority. The hot keys
    /// run in the first frame's slot, so a system-wide key works long before the 10 s failsafe.
    @Test func platformServicesPostAtTheirDesignPriority() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        func run(_ name: String) -> @MainActor @Sendable () -> Void { { ran.names.append(name) } }
        LaunchServicePosts.platform(globalHotKeys: run("GlobalHotKeys.start"), borders: run("Borders.observe"), glass: run("Glass.observe"),
                                    keepAwake: run("KeepAwake.start"), mobile: run("Mobile.follow"), notifications: run("Notifications.follow"),
                                    macScreenSettings: run("MacScreen.followSettings"), deviceHub: run("DeviceHub.start"),
                                    computerUseHelper: run("ComputerUseHelper.follow"),
                                    hibernationMeasurements: run("Hibernation.measure"), apps: run("Apps.start"), macScreen: run("MacScreen.activate"),
                                    updateFeed: run("UpdateFeedPosting.follow")).post(on: f.order.startup)
        f.hand.drain()
        let firstFrame = ["GlobalHotKeys.start", "Borders.observe", "Glass.observe"]
        let afterStartup = ["KeepAwake.start", "Mobile.follow", "Notifications.follow", "MacScreen.followSettings", "DeviceHub.start",
                            "ComputerUseHelper.follow", "Hibernation.measure", "Apps.start", "MacScreen.activate",
                            "UpdateFeedPosting.follow"]
        let posted = f.order.startup.log.records.map { ($0.name.description, $0.priority) }
        #expect(posted.map(\.0) == firstFrame + afterStartup)
        for (name, priority) in posted {
            #expect(priority == (firstFrame.contains(name) ? StartupPriority.afterFirstFrame : StartupPriority.afterStartup), "\(name)")
        }
        #expect(f.order.startup.log.records.allSatisfy { $0.destination == .main })
        f.fire()
        #expect(ran.names.isEmpty, "nothing runs before the first frame")
        f.order.startup.firstFrameCommitted()
        for _ in 0..<firstFrame.count { f.fire() }
        #expect(ran.names == firstFrame, "the hot keys, borders and glass run after the first frame, before startup completes")
        f.complete()
        for _ in 0..<(2 * afterStartup.count) { f.fire() }
        #expect(ran.names == firstFrame + afterStartup, "each platform service ran once, in post order")
    }

    /// An agent- or bench-launched build posts no hot key start: it never takes the person's system-wide keys.
    @Test func anIsolatedLaunchPostsNoHotKeys() {
        let f = LaunchOrderFixture()
        let none: @MainActor @Sendable () -> Void = {}
        LaunchServicePosts.platform(globalHotKeys: nil, borders: none, glass: none, keepAwake: none, mobile: none, notifications: none,
                                    macScreenSettings: none, deviceHub: none, computerUseHelper: none,
                                    hibernationMeasurements: none, apps: none, macScreen: none, updateFeed: none).post(on: f.order.startup)
        f.hand.drain()
        let names = f.order.startup.log.records.map(\.name.description)
        #expect(!names.contains("GlobalHotKeys.start"))
        #expect(names.first == "Borders.observe")
    }

    @Test func aVisibleWebKitChatAtRestoreTakesTheFirstFrameSlot() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        let slot = AgentPageWarmupSlot(startup: f.order.startup) { ran.names.append("warm") }
        slot.restored(showsWebKitAgentChat: true)
        f.hand.drain()
        #expect(slot.postedPriority == .afterFirstFrame)
        #expect(f.order.startup.log.records.map(\.name.description) == ["AgentPane.webKitWarmup"])
        f.fire()
        #expect(ran.names.isEmpty, "it waits for the first frame")
        f.order.startup.firstFrameCommitted()
        f.fire()
        #expect(ran.names == ["warm"], "before startup completes")
    }

    @Test func aRestoreAfterTheFirstFrameStillTakesTheSlot() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        let slot = AgentPageWarmupSlot(startup: f.order.startup) { ran.names.append("warm") }
        f.order.startup.firstFrameCommitted()
        f.fire()
        slot.restored(showsWebKitAgentChat: true)
        f.hand.drain()
        f.fire()
        #expect(ran.names == ["warm"], "the restore came after the first frame: it runs at the next frame")
    }

    @Test func noVisibleChatAtRestoreWaitsForStartupComplete() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        let slot = AgentPageWarmupSlot(startup: f.order.startup) { ran.names.append("warm") }
        slot.restored(showsWebKitAgentChat: false)
        f.hand.drain()
        #expect(slot.postedPriority == .afterStartup)
        f.order.startup.firstFrameCommitted()
        f.fire()
        #expect(ran.names.isEmpty, "afterStartup waits for completion")
        f.complete()
        f.fire()
        f.fire()
        #expect(ran.names == ["warm"])
        slot.restored(showsWebKitAgentChat: true)
        f.hand.drain()
        f.fire()
        #expect(ran.names == ["warm"], "posted once")
    }

    @Test func startupCompleteWithNoRestorePostsItAtAfterStartup() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        let slot = AgentPageWarmupSlot(startup: f.order.startup) { ran.names.append("warm") }
        f.complete()
        f.hand.drain()
        f.fire()
        f.fire()
        #expect(slot.postedPriority == .afterStartup)
        #expect(ran.names == ["warm"], "a launch with no restore (daemon unavailable, failsafe) still warms")
    }
}

/// The service starts that ran, in order.
@MainActor
private final class LaunchServiceRan {
    var names: [String] = []
}
