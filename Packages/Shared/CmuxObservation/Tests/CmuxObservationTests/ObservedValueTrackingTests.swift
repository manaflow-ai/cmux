import CmuxObservation
import Observation
import Testing

@Observable
private final class TrackingModel {
    var value = 0
}

@Suite("Observed value tracking")
@MainActor
struct ObservedValueTrackingTests {
    @Test("subscriber churn does not arm another registrar entry")
    func subscriberChurnDoesNotRearmAnIdleSource() async {
        let model = TrackingModel()
        var readCount = 0
        let tracking = ObservedValueTracking {
            readCount += 1
            return model.value
        }

        var first = tracking.changes().makeAsyncIterator()
        #expect(await first.next() == 0)
        let countAfterFirstSubscriber = readCount
        var second = tracking.changes().makeAsyncIterator()
        #expect(await second.next() == 0)
        #expect(readCount == countAfterFirstSubscriber)
        tracking.cancel()
    }

    @Test("cancellation releases an idle read capture")
    func cancellationReleasesIdleReadCapture() async {
        let model = TrackingModel()
        weak var weakProbe: Probe?
        var tracking: ObservedValueTracking<Int>?
        var iterator: AsyncStream<Int>.Iterator?
        do {
            let probe = Probe()
            weakProbe = probe
            tracking = ObservedValueTracking {
                _ = probe
                return model.value
            }
            iterator = tracking?.changes().makeAsyncIterator()
        }
        #expect(weakProbe != nil)
        #expect(await iterator?.next() == 0)
        tracking?.cancel()
        tracking = nil
        #expect(weakProbe == nil)
    }

    @Test("one mutation is replayed to every subscriber")
    func mutationReachesEverySubscriber() async {
        let model = TrackingModel()
        let tracking = ObservedValueTracking { model.value }
        var first = tracking.changes().makeAsyncIterator()
        var second = tracking.changes().makeAsyncIterator()
        #expect(await first.next() == 0)
        #expect(await second.next() == 0)
        model.value = 1
        #expect(await first.next() == 1)
        #expect(await second.next() == 1)
        tracking.cancel()
    }

    private final class Probe {}
}
