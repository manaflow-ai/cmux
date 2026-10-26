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
            pageHostPool: { ran.names.append("PageHostPool.start") },
            agentTabImport: { ran.names.append("AgentTabImport.start") },
            rightSidebarIcons: { ran.names.append("RightSidebar.prewarm") }
        ).post(on: f.order.startup)
        f.hand.drain()
        let posted = f.order.startup.log.records.map { ($0.name.description, $0.priority) }
        #expect(posted.map(\.0) == ["SSH.start", "FreeTierAttest.start", "ServerReach.start", "Updater.start",
                                    "EmptyWorkspaceRepair.observe", "ChromiumWarmup.start", "NewTabSpares.hooks",
                                    "NewTabSpares.warm", "PageHostPool.start", "AgentTabImport.start", "RightSidebar.prewarm"])
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
                              "PageHostPool.start", "AgentTabImport.start", "RightSidebar.prewarm"],
                "each post ran its one service once, in post order within its priority")
        #expect(f.order.startup.log.records.allSatisfy { $0.durationNanos != nil }, "one record per task, each with its run")
    }

    /// p08-startup-031: the starts `AppServices.init` made before the first frame are posts; the update
    /// sheet is attached before the updater starts (both afterStartup, in post order).
    @Test func initServiceStartsArePostsAndTheSheetIsAttachedBeforeTheUpdaterStarts() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        LaunchServicePosts.serviceStarts(
            windowOcclusion: { ran.names.append("SurfaceInvariant.observeWindowOcclusion") },
            inputVerification: { ran.names.append("InputVerification.start") },
            notifications: { ran.names.append("Notifications.start") },
            updateSheet: { ran.names.append("Updater.attach") },
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
        #expect(ran.names == firstFrame + ["Updater.attach", "ServerUpdates.start", "BrowserHost.start", "Updater.start"],
                "the sheet is attached before the updater starts; the browser host after startup")
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
