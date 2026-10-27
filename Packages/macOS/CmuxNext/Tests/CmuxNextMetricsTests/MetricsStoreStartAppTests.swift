import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// `MetricsStore.startApp`'s `attached` (p09-observability-089): it runs once the runtime has a store, so a recorder
/// that kept samples while none was attached (the blocking detector's early sites) records them then.
struct MetricsStoreStartAppTests {
    /// What `attached` saw: whether the runtime had a store when it ran.
    private final class Seen: Sendable {
        private let calls = Mutex<[Bool]>([])
        var all: [Bool] { calls.withLock { $0 } }
        func note(_ attached: Bool) { calls.withLock { $0.append(attached) } }
    }

    @Test func attachedRunsAfterTheStoreIsAttached() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "metrics-start-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = TraceRuntime(role: .app)
        let seen = Seen()

        MetricsStore.startApp(directory: folder, channel: "nightly", work: ChildMetricsReaderTests.InlineFiles(), runtime: runtime,
                              attached: { seen.note(MetricsStore.attached(to: runtime) != nil) })

        #expect(seen.all == [true])
    }

    @Test func attachedRunsWhenTheRuntimeHadAStore() throws {
        let runtime = TraceRuntime(role: .app)
        let earlier = MetricsStore(role: .app, profile: MetricsProfile(appVersion: "1", buildNumber: "1", channel: "nightly",
                                                                       osVersion: "26.1.0", hardwareClass: "Mac16,10",
                                                                       bootSessionUUID: Array(repeating: 1, count: 16),
                                                                       buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26)),
                                   catalog: [.blockingViolations])
        earlier.attach(to: runtime)
        let seen = Seen()

        MetricsStore.startApp(directory: FileManager.default.temporaryDirectory, channel: "nightly",
                              work: ChildMetricsReaderTests.InlineFiles(), runtime: runtime,
                              attached: { seen.note(MetricsStore.attached(to: runtime) === earlier) })

        #expect(seen.all == [true])
    }
}
