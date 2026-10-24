import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A control work-queue frame (a script's CLI calls, 1000 a second under load) marks the control snapshot stale
/// instead of building it: each drained frame mapped the topology and walked every mounted pane on the main thread,
/// a full publish every display frame while a script ran. The snapshot is built when a read needs it, once for
/// any number of frames before that read, and still covers the writes those frames made (read-your-writes).
@MainActor @Suite(.serialized)
struct ControlSnapshotLazyPublishTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// Runs each frame's work on the next main-actor turn (no display link in a test process).
    struct SoonFrames: ControlFrameSource {
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { Task { @MainActor in work() } }
    }

    @Test func workQueueFramesWithNoReaderBuildNothingAndOneReadBuildsOnce() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)), frameSource: SoonFrames())
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames())
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        let builds = publisher.builds

        for _ in 0..<100 {
            try await router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}
        }
        for _ in 0..<8 { await Task.yield() }
        #expect(publisher.builds == builds, "\(publisher.builds - builds) snapshot builds for 100 work-queue frames with no reader (want 0)")

        // One read: the snapshot is built for it, once.
        let reply = await router.handle(ControlRequest(method: "system.ping"))
        #expect((try? reply.get()) != nil)
        #expect(publisher.builds == builds + 1, "\(publisher.builds - builds) builds for one read after the frames (want 1)")
        // A second read with nothing changed builds nothing.
        _ = await router.handle(ControlRequest(method: "system.ping"))
        #expect(publisher.builds == builds + 1)
    }
}
