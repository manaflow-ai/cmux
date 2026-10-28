import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
@testable import CmuxNextBrowser
import CmuxNextMetrics
import Testing

/// Chromium's UMA snapshot folded as `chromium.*` (p09-observability task 107): only the allowlist is asked for,
/// only when a trigger calls ``CEFHistogramHarvest/harvest()``, and a fork without the call is counted unsupported.
@MainActor
@Suite struct CEFHistogramHarvestTests {
    /// The names each snapshot asked for, in order.
    @MainActor final class Asked {
        var names: [[String]] = []
    }

    nonisolated private static func store() -> MetricsStore {
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "7", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 28))
        return MetricsStore(role: .app, profile: profile, pid: 4242, catalog: [])
    }

    private static let keyPress = CEFHistogramDelta(
        name: "EventLatency.KeyPressed.TotalLatency", sum: 42_000, count: 3,
        buckets: [.init(minimum: 10_000, maximum: 12_000, count: 2), .init(minimum: 20_000, maximum: 24_000, count: 1)])

    @Test func aHarvestAsksForTheAllowlistOnceAndFoldsItAsChromiumHistograms() async throws {
        let asked = Asked()
        let store = Self.store()
        let harvest = CEFHistogramHarvest(snapshot: { names in
            asked.names.append(names)
            return .success([Self.keyPress, CEFHistogramDelta(name: "Memory.Browser.PrivateMemoryFootprint", sum: 1, count: 1, buckets: [])])
        }, store: { store })
        #expect(asked.names.isEmpty, "making the harvest asks Chromium nothing: no timer, no polling")

        let outcome = await harvest.harvest()
        #expect(outcome == .folded(histograms: 1, samples: 3), "a name Chromium sent outside the allowlist is dropped")
        #expect(asked.names == [CEFHistogramHarvest.allowlist])
        #expect(Set(CEFHistogramHarvest.allowlist) == Set(HistogramID.Chromium.allCases.map(\.rawValue)))
        let folded = try #require(store.delta().histograms.first { $0.name == "chromium.EventLatency.KeyPressed.TotalLatency" })
        #expect(folded.count == 3 && folded.sum == 42_000)
        #expect(folded.buckets.map(\.index) == [10_000, 20_000])
        #expect(await harvest.tally.folded == 1)
    }

    @Test func aNameOutsideTheAllowlistIsRefusedBeforeChromiumIsAsked() async {
        let asked = Asked()
        let harvest = CEFHistogramHarvest(snapshot: { names in
            asked.names.append(names)
            return .success([])
        }, store: { Self.store() })
        #expect(await harvest.snapshot(names: ["Memory.Browser.PrivateMemoryFootprint"]) == .failure(.refused))
        #expect(await harvest.snapshot(names: ["EventLatency.KeyPressed.TotalLatency", "UMA.Anything"]) == .failure(.refused))
        #expect(await harvest.snapshot(names: []) == .failure(.refused))
        #expect(asked.names.isEmpty)
        #expect(await harvest.snapshot(names: ["EventLatency.KeyPressed.TotalLatency"]) == .success([]))
        #expect(asked.names == [["EventLatency.KeyPressed.TotalLatency"]])
    }

    @Test func anOldForkIsCountedUnsupportedAndFoldsNothing() async {
        let store = Self.store()
        let harvest = CEFHistogramHarvest(snapshot: { _ in .failure(.unsupported) }, store: { store })
        #expect(await harvest.harvest() == .failed(.unsupported))
        #expect(await harvest.tally.unsupported == 1)
        #expect(store.delta().isEmpty)
    }

    @Test func noStoreAsksNothing() async {
        let asked = Asked()
        let harvest = CEFHistogramHarvest(snapshot: { names in
            asked.names.append(names)
            return .success([Self.keyPress])
        }, store: { nil })
        #expect(await harvest.harvest() == .noStore)
        #expect(asked.names.isEmpty)
    }

    @Test func theShimsAnswersMapToTheirErrors() {
        #expect(CEFEngine.histogramSnapshotError(nil) == .unsupported, "a shim without the export")
        #expect(CEFEngine.histogramSnapshotError(-2) == .unsupported, "a fork without cmux_cef_histogram_snapshot, or host mode")
        #expect(CEFEngine.histogramSnapshotError(-1) == .refused)
        #expect(CEFEngine.histogramSnapshotError(0) == .notStarted)
    }

    @Test func theCallbackCopiesEachDeltaAndTheEndCallResumesWithThem() async throws {
        typealias Answer = Result<[CEFHistogramDelta], CEFHistogramHarvestError>
        let result = try await withOnceContinuation { (continuation: OnceContinuation<Answer, OnceContinuationError>) in
            let box = CEFHistogramSnapshotBox(continuation: continuation)
            // SAFETY: the +1 is the snapshot's; the end call below takes it back once.
            let context = unsafe Unmanaged.passRetained(box).toOpaque()
            var triples: [Int64] = [10_000, 12_000, 2, 20_000, 24_000, 1]
            "EventLatency.KeyPressed.TotalLatency".withCString { name in
                triples.withUnsafeBufferPointer { buffer in
                    // SAFETY: the name and the two triples are valid during the call, as the fork passes them.
                    unsafe cefHistogramSnapshotCallback(context, name, 42_000, 3, buffer.baseAddress, 2)
                }
            }
            // The buffer is gone after the call: the box kept a copy.
            triples = [0, 0, 0, 0, 0, 0]
            unsafe cefHistogramSnapshotCallback(context, nil, 0, 0, nil, 0)
        }
        #expect(result == .success([Self.keyPress]))
    }
}
