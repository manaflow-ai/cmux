import AppKit
@testable import CmuxNextApp
import CmuxNextControl
@testable import CmuxNextDaemon
import Foundation
import os
import Testing

/// No O(all) work per event (perf-lead.md cause 6, row 8). The control snapshot publisher
/// rebuilt the whole topology (every workspace of every machine, each pane's app facts) on the
/// frame after every key or activation notice, and again whenever anything its build read
/// changed. A window switch (Cmd-`, a click on another window, Cmd-Tab back to another window)
/// changes the registry's window order (`WindowRegistry.recency`, through
/// `WindowController.windowDidBecomeKey` and `WindowManager.didActivate`) and the location
/// trail (Search Tabs facts): neither moves a workspace, yet each rebuilt every one. A switch
/// moves only the window facts (which window is key, the focus): O(windows), and the location
/// trail Search Tabs orders by (republished alone, on the trail's own change). It does not move
/// the closed-tab list of Search Tabs (O(closed history), rebuilt only on a close).
///
/// Rebuilds are counted through the publisher's own seam (`onPublish`, the parts each publish
/// built), never through a process-wide list: suites run in parallel in one process, and
/// another suite's publisher or window closes must not reach this count.
@MainActor @Suite(.serialized) struct ControlSnapshotKeyChangeTests {
    init() {
        // `WindowManager.active` and the window controllers read NSApp: create it before AppServices.
        _ = NSApplication.shared
    }

    private final class NoActions: ControlActionExecutor {
        @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .unknownAction }
    }

    /// Display frames the test runs by hand, so nothing publishes behind its back.
    private final class ManualFrames: ControlFrameSource {
        // `scheduleFrame` is a nonisolated requirement of a Sendable protocol, so the hand-off list
        // cannot be main-actor state; the lock guards only that append and the swap in `run`.
        private let pending = OSAllocatedUnfairLock<[@MainActor @Sendable () -> Void]>(initialState: [])

        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            pending.withLock { $0.append(work) }
        }

        /// Runs one display frame: the frames scheduled so far. A frame scheduled while it runs
        /// (a publish held by the publisher's interval looks again each frame) waits for the next
        /// call, so a held publish never spins: it goes once the test's clock passes its wait.
        @MainActor func run() {
            let work = pending.withLock { list in
                defer { list = [] }
                return list
            }
            for frame in work { frame() }
        }
    }

    /// The publisher's clock: it moves only when the test moves it, so a held model publish waits
    /// for the test, not for real time.
    @MainActor private final class TestClock {
        var now = ContinuousClock.now

        /// Moves past the publisher's model-change interval: every held part is due.
        func passTheInterval() { now = now + ControlSnapshotPublisher.modelChangeInterval + .milliseconds(1) }
    }

    /// The window the test says AppKit made key (`AppServices.keyWindowSource`): the host's own
    /// key window never reaches the run.
    @MainActor private final class KeyWindow {
        var window: NSWindow?
    }

    /// The parts this test's publisher built, counted per part.
    @MainActor private final class Rebuilds {
        var topology = 0
        var closedTabs = 0

        func note(_ parts: ControlSnapshotPublisher.Parts) {
            if parts.contains(.topology) { topology += 1 }
            if parts.contains(.closedTabs) { closedTabs += 1 }
        }
    }

    /// Lets the publisher's tracking hops (main-actor tasks) run, then every frame they scheduled.
    private static func settle(_ frames: ManualFrames) async {
        for _ in 0..<4 {
            for _ in 0..<16 { await Task.yield() }
            frames.run()
        }
    }

    private static func publisher(_ services: AppServices, frames: ManualFrames, notices: NotificationCenter,
                                  clock: TestClock, rebuilds: Rebuilds) -> (ControlRouter, ControlSnapshotPublisher) {
        let identity = ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                       processID: getpid())
        let router = ControlRouter(identity: identity, executor: NoActions())
        return (router, ControlSnapshotPublisher(router: router, services: services, frames: frames, notices: notices,
                                                 now: { [clock] in clock.now },
                                                 onPublish: { [rebuilds] in rebuilds.note($0) }))
    }

    /// A connected local daemon with workspaces `k0` and `k1`, one terminal each.
    private static func services() throws -> AppServices {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let keys = ["k0", "k1"]
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            let n = UInt64(index + 1)
            let pane = PaneSnapshot(id: PaneID(rawValue: n), tabs: [TabSnapshot(surface: SurfaceID(rawValue: n), title: "~")])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: n), key: WorkspaceKey(rawValue: key), name: key,
                                     screens: [ScreenSnapshot(id: ScreenID(rawValue: n), layout: .leaf(pane.id), panes: [pane])])
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        store.apply(snapshot: tree)
        return services
    }

    @Test func aWindowSwitchMapsNoWorkspaceAgainAndStillMovesTheKeyAndTheFocus() async throws {
        let services = try Self.services()
        let ids = services.machines.local.store.workspaces.map(\.id)
        try #require(ids.count == 2)
        let a = try #require(services.windows.openWindow(workspaces: [ids[0]], frame: CGRect(x: 100, y: 100, width: 900, height: 600)))
        let b = try #require(services.windows.openWindow(workspaces: [ids[1]], frame: CGRect(x: 160, y: 160, width: 900, height: 600)))
        defer {
            for controller in [a, b] {
                controller.teardown()
                controller.window?.close()
            }
        }
        let key = KeyWindow()
        services.keyWindowSource = { [key] in key.window }

        let frames = ManualFrames()
        let rebuilds = Rebuilds()
        let clock = TestClock()
        // The publisher hears this test's notices only, and nothing else hears them.
        let center = NotificationCenter()
        let (router, publisher) = Self.publisher(services, frames: frames, notices: center, clock: clock, rebuilds: rebuilds)
        publisher.start()
        defer { publisher.stop() }
        await Self.settle(frames)
        let before = rebuilds.topology, closedBefore = rebuilds.closedTabs
        #expect(before >= 1, "start publishes the whole snapshot once")

        // Key moves A -> B -> A, the way AppKit drives it: the window that resigns, then the one
        // that becomes key (its controller's delegate methods, and the notices the publisher
        // hears, on the test's own center so no delegate or other suite hears them).
        var previous: WindowController?
        for target in [b, a, b, a] {
            let generation = router.snapshots.current.generation
            if let previous, let window = previous.window {
                key.window = nil
                previous.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
                center.post(name: NSWindow.didResignKeyNotification, object: window)
            }
            let window = try #require(target.window)
            key.window = window
            target.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            await Self.settle(frames)
            previous = target

            // The real path ran: the registry's window order follows the key window.
            #expect(services.windows.registry.value.recency.first == target.state.id)
            let topology = router.snapshots.current.topology
            #expect(router.snapshots.current.generation > generation, "a key change published nothing")
            #expect(topology.windows.first { $0.id == target.state.id }?.isKey == true, "the key window is not key in the snapshot")
            #expect(topology.windows.filter(\.isKey).count == 1, "not exactly one window is key in the snapshot")
            #expect(topology.focus.windowID == target.state.id, "the focus did not follow the key window")

            // The switch settles somewhere new (here a top page of the window): the trail moves,
            // and Search Tabs' recency in the snapshot follows it, without the closed list.
            services.locationTrail.pageDidShow(.home, title: "Home", in: target)
            await Self.settle(frames)
            #expect(router.snapshots.current.tabSearch.lastActive == TabSearchFactsBuilder.lastActive(services),
                    "the trail moved and the snapshot kept the old recency")
        }
        // A topology change the switches caused would be held, not gone: let every wait end.
        clock.passTheInterval()
        await Self.settle(frames)
        #expect(rebuilds.topology == before,
                "a window switch rebuilt every workspace's control facts (\(rebuilds.topology - before) topology publishes)")
        #expect(rebuilds.closedTabs == closedBefore,
                "a window switch rebuilt the closed-tab list (\(rebuilds.closedTabs - closedBefore) rebuilds)")
    }

    @Test func activationNoticesMapNoWorkspaceAgain() async throws {
        let services = try Self.services()
        let key = KeyWindow()
        services.keyWindowSource = { [key] in key.window }
        let frames = ManualFrames()
        let rebuilds = Rebuilds()
        let clock = TestClock()
        // The publisher hears this test's notices only, and nothing else hears them.
        let center = NotificationCenter()
        let (_, publisher) = Self.publisher(services, frames: frames, notices: center, clock: clock, rebuilds: rebuilds)
        publisher.start()
        defer { publisher.stop() }
        await Self.settle(frames)
        let before = rebuilds.topology

        // A Cmd-Tab away and back, and a panel (the palette) taking the keys and giving them back.
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        for _ in 0..<3 {
            center.post(name: NSApplication.didResignActiveNotification, object: nil)
            await Self.settle(frames)
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            center.post(name: NSWindow.didBecomeKeyNotification, object: panel)
            await Self.settle(frames)
            center.post(name: NSWindow.didResignKeyNotification, object: panel)
            await Self.settle(frames)
        }
        clock.passTheInterval()
        await Self.settle(frames)
        #expect(rebuilds.topology == before,
                "a key or activation notice rebuilt every workspace's control facts (\(rebuilds.topology - before) topology publishes)")
    }

    /// A hover card, a toast, a sheet or a Chromium popup closing is no window of the window
    /// manager: the window list and every workspace stay as they are.
    @Test func aWindowTheManagerDoesNotOwnClosingMapsNoWorkspaceAgain() async throws {
        let services = try Self.services()
        let frames = ManualFrames()
        let rebuilds = Rebuilds()
        let clock = TestClock()
        // The publisher hears this test's notices only, and nothing else hears them.
        let center = NotificationCenter()
        let (_, publisher) = Self.publisher(services, frames: frames, notices: center, clock: clock, rebuilds: rebuilds)
        publisher.start()
        defer { publisher.stop() }
        await Self.settle(frames)
        let before = rebuilds.topology

        for _ in 0..<3 {
            let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
            popup.isReleasedWhenClosed = false
            center.post(name: NSWindow.willCloseNotification, object: popup)
            await Self.settle(frames)
        }
        clock.passTheInterval()
        await Self.settle(frames)
        #expect(rebuilds.topology == before,
                "a window no controller owns closed and every workspace's control facts were rebuilt (\(rebuilds.topology - before) topology publishes)")
    }

    /// Under load a topology publish is held most of the time (agent status ticks, printing
    /// terminals). A window switch and the trail move it brings publish the window facts and the
    /// trail on the next frame and leave the held topology waiting: before, the trail's plain
    /// invalidate cancelled the hold and a key change flushed it, so each switch paid for every
    /// workspace on its own frame.
    @Test func aHeldTopologyWaitsThroughAWindowSwitchAndATrailMove() async throws {
        let services = try Self.services()
        let ids = services.machines.local.store.workspaces.map(\.id)
        try #require(ids.count == 2)
        let a = try #require(services.windows.openWindow(workspaces: [ids[0]], frame: CGRect(x: 100, y: 100, width: 900, height: 600)))
        let b = try #require(services.windows.openWindow(workspaces: [ids[1]], frame: CGRect(x: 160, y: 160, width: 900, height: 600)))
        defer {
            for controller in [a, b] {
                controller.teardown()
                controller.window?.close()
            }
        }
        let key = KeyWindow()
        services.keyWindowSource = { [key] in key.window }
        let frames = ManualFrames()
        let rebuilds = Rebuilds()
        let clock = TestClock()
        let center = NotificationCenter()
        let (router, publisher) = Self.publisher(services, frames: frames, notices: center, clock: clock, rebuilds: rebuilds)
        publisher.start()
        defer { publisher.stop() }
        await Self.settle(frames)
        let before = rebuilds.topology

        // A tracked read of the topology changes (the store applied a batch) right after the
        // start's publish: the topology is held for the interval.
        let store = services.daemon.store
        store.appliedSequence &+= 1
        await Self.settle(frames)
        #expect(rebuilds.topology == before, "a model change inside the interval published the topology at once")

        // Inside the interval: B becomes key, then the switch settles on B's page (the trail).
        let window = try #require(b.window)
        key.window = window
        b.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await Self.settle(frames)
        #expect(router.snapshots.current.topology.focus.windowID == b.state.id, "the window facts waited for the topology")
        #expect(rebuilds.topology == before, "a key change flushed the held topology (every workspace on the switch's frame)")
        services.locationTrail.pageDidShow(.home, title: "Home", in: b)
        await Self.settle(frames)
        #expect(router.snapshots.current.tabSearch.lastActive == TabSearchFactsBuilder.lastActive(services),
                "the trail waited for the held topology")
        #expect(rebuilds.topology == before, "a trail move cancelled the topology's hold (every workspace on the switch's frame)")

        // The wait ends: the held topology goes once, with the change it was held for.
        clock.passTheInterval()
        await Self.settle(frames)
        #expect(rebuilds.topology == before + 1, "the held topology never went (\(rebuilds.topology - before) publishes)")
        #expect(router.snapshots.current.topology.daemonSequence == store.appliedSequence)
    }
}
