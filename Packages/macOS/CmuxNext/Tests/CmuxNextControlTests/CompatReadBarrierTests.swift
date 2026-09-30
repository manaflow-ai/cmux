import CmuxNextDaemon
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Compat reads answer from the published `ControlSnapshot` (architecture.md
/// 5a), never from a per-call `list-workspaces`: under the CLI storm that
/// round trip missed the 2 s deadline for ~15% of reads.
@Suite(.timeLimit(.minutes(1))) struct CompatReadBarrierTests {
    /// The service holds its router weakly; the caller keeps both alive.
    func install() -> (ControlRouter, CompatService) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        // No daemon connection: any daemon request fails at once.
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        service.install(on: router)
        return (router, service)
    }

    @Test func identifyAnswersFromTheSnapshotWithoutTheDaemon() async throws {
        let (router, _) = install()
        let sample = ControlSnapshot.sample()
        router.snapshots.publish { $0 = sample }
        let identify = try await router.handle(ControlRequest(method: "system.identify")).get()
        // With a daemon round trip the missing connection leaves focus null.
        let focused = try #require(identify["focused"]?.objectValue, "identify asked the daemon: \(identify)")
        #expect(focused["surface_ref"] != nil || focused["surface_id"] != nil, "\(focused)")
        let tree = try await router.handle(ControlRequest(method: "system.tree")).get()
        #expect(tree["windows"]?.arrayValue?.isEmpty == false)
    }
}
