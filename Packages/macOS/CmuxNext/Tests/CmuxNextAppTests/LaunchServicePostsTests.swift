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
            updater: { ran.names.append("Updater.start") }
        ).post(on: f.order.startup)
        LaunchServicePosts.laterTabs(
            chromiumWarmup: { ran.names.append("ChromiumWarmup.start") },
            spareHooks: { ran.names.append("NewTabSpares.hooks") },
            spareWarming: { ran.names.append("NewTabSpares.warm") },
            pageHostPool: { ran.names.append("PageHostPool.start") },
            agentTabImport: { ran.names.append("AgentTabImport.start") }
        ).post(on: f.order.startup)
        f.hand.drain()
        let posted = f.order.startup.log.records.map { ($0.name.description, $0.priority) }
        #expect(posted.map(\.0) == ["SSH.start", "FreeTierAttest.start", "ServerReach.start", "Updater.start",
                                    "ChromiumWarmup.start", "NewTabSpares.hooks", "NewTabSpares.warm", "PageHostPool.start",
                                    "AgentTabImport.start"])
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
        for _ in 0..<10 { f.fire() }
        #expect(ran.names == ["SSH.start", "ChromiumWarmup.start", "NewTabSpares.hooks", "FreeTierAttest.start",
                              "ServerReach.start", "Updater.start", "NewTabSpares.warm",
                              "PageHostPool.start", "AgentTabImport.start"],
                "each post ran its one service once, in post order within its priority")
        #expect(f.order.startup.log.records.allSatisfy { $0.durationNanos != nil }, "one record per task, each with its run")
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

    /// p08-startup-021: a restore that shows a remote-terminal tab makes the remote-terminal service
    /// after the first frame and before startup completes; one that shows none posts nothing.
    @Test func aShownRemoteTerminalAtRestoreStartsItsServiceAfterTheFirstFrame() {
        let f = LaunchOrderFixture()
        let ran = LaunchServiceRan()
        LaunchServicePosts.restoredRemoteTerminals(shown: false) { ran.names.append("hidden") }.post(on: f.order.startup)
        LaunchServicePosts.restoredRemoteTerminals(shown: true) { ran.names.append("RemoteTerminals.start") }.post(on: f.order.startup)
        f.hand.drain()
        let posted = f.order.startup.log.records.map { ($0.name.description, $0.priority) }
        #expect(posted.map(\.0) == ["RemoteTerminals.start"], "a restore with no remote-terminal tab posts nothing")
        #expect(posted.first?.1 == .afterFirstFrame)
        f.fire()
        #expect(ran.names.isEmpty, "it waits for the first frame")
        f.order.startup.firstFrameCommitted()
        f.fire()
        #expect(ran.names == ["RemoteTerminals.start"], "before startup completes")
    }
}

/// The service starts that ran, in order.
@MainActor
private final class LaunchServiceRan {
    var names: [String] = []
}
