import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import Foundation
import Testing

/// RESIZE MAIN BUDGET (cmux-ad m16 item 5): a drag bench sends one `debug.mouse` request per display frame. Each
/// request's work-queue frame marked the control snapshot stale, so the next request (the next frame's move) mapped the
/// topology again before it ran: 0.4-1.0 ms of main thread in every drag frame of the bench (Time Profiler of job
/// ed08902c, `ControlSnapshotPublisher.publishNow` under `ControlRouter.handle`), which a person's drag never pays.
/// `debug.mouse` posts events, which run after its frame, and moves the synthesized pointer: its frame changes nothing
/// the snapshot shows, so it leaves the snapshot fresh.
@MainActor @Suite(.serialized)
struct DebugMouseSnapshotTests {
    @Test func pointerMovesFromTheSocketBuildNoTopology() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let frames = ControlSnapshotLazyPublishTests.SoonFrames()
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: ControlSnapshotLazyPublishTests.Executor(), configuration: .init(requestDeadline: .seconds(30)),
                                   frameSource: frames)
        router.register([AppControl.debugMouseMethod(services)])
        // A private notification center: other suites' windows keying and closing must not publish this snapshot.
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: frames, notifications: NotificationCenter())
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        // A first read builds whatever the start left stale.
        _ = await router.handle(ControlRequest(method: "system.ping"))
        let builds = publisher.builds

        // A drag's moves, as bench-terminal-resize sends them (no press, no release), one request per frame.
        for step in 0..<20 {
            let reply = await router.handle(ControlRequest(method: "debug.mouse", params: [
                "action": .string("drag"), "x": .number(Double(100 + step)), "y": .number(100), "to_x": .number(Double(101 + step)),
                "to_y": .number(100), "steps": .number(1), "press": .bool(false), "release": .bool(false),
            ]))
            #expect((try? reply.get()) != nil, "debug.mouse failed: \(reply)")
        }
        for _ in 0..<8 { await Task.yield() }
        #expect(publisher.builds == builds, "\(publisher.builds - builds) topology builds for 20 debug.mouse moves (want 0)")
        #expect(!router.snapshots.isStale, "the moves left the snapshot stale: the next read maps the topology again")
    }

    /// Frames that never run: the publisher's own next-frame publish never comes, so only the snapshot's stale mark
    /// can make a read see a change.
    struct NeverFrames: ControlFrameSource {
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {}
    }

    /// Review of #36264 (read-your-writes): a request that leaves the snapshot fresh (`debug.mouse`) can still change
    /// what the snapshot shows inside its own frame (a scroll that moves the focus) or through the events it posts (a
    /// click). The publisher's observation sees every such change, inside the mutation, and marks the snapshot stale
    /// there, so the next read builds it, whatever request or event made the change.
    @Test func aChangeMadeByARequestThatLeavesTheSnapshotFreshIsReadByTheNextRequest() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: ControlSnapshotLazyPublishTests.Executor(), configuration: .init(requestDeadline: .seconds(30)),
                                   frameSource: ControlSnapshotLazyPublishTests.SoonFrames())
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-ryw","generation":"g1"}"#.utf8))
        router.register([ControlMethod.mainActor("test.observed_change") { [services] _ in
            services.daemon.store.noteHandshake(identity)
            services.daemon.store.connectionState = .connected(identity)
            return .value(.null)
        }.leavingSnapshotFresh()])
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: NeverFrames(), notifications: NotificationCenter())
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        #expect(await router.snapshots.fresh().topology.daemonState == "connecting")

        _ = await router.handle(ControlRequest(method: "test.observed_change"))
        let read = await router.snapshots.fresh()
        #expect(read.topology.daemonState == "connected", "the next read shows \(read.topology.daemonState): the change went unread")
    }
}
