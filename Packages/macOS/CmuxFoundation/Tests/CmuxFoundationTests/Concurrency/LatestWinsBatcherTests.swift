import Foundation
import Testing
@testable import CmuxFoundation

@MainActor
@Suite struct LatestWinsBatcherTests {
    @Test func burstDrainsLatestValueForEachKeyAfterQuietDeadline() {
        let scheduler = ManualDeadlineScheduler()
        let batcher = LatestWinsBatcher<String, Int>(
            quietDelay: 0.05,
            maximumDelay: 0.2,
            scheduler: scheduler.schedule
        )
        var drained: [[String: Int]] = []

        batcher.submit(1, for: "workspace") { drained.append($0) }
        batcher.submit(2, for: "workspace") { drained.append($0) }
        batcher.submit(3, for: "history") { drained.append($0) }

        #expect(drained.isEmpty)
        scheduler.advance(by: 0.049)
        #expect(drained.isEmpty)
        scheduler.advance(by: 0.001)
        #expect(drained == [["workspace": 2, "history": 3]])
    }

    @Test func continuousBurstDrainsAtMaximumDeadline() {
        let scheduler = ManualDeadlineScheduler()
        let batcher = LatestWinsBatcher<String, Int>(
            quietDelay: 0.1,
            maximumDelay: 0.25,
            scheduler: scheduler.schedule
        )
        var drained: [[String: Int]] = []

        batcher.submit(1, for: "value") { drained.append($0) }
        scheduler.advance(by: 0.08)
        batcher.submit(2, for: "value") { drained.append($0) }
        scheduler.advance(by: 0.08)
        batcher.submit(3, for: "value") { drained.append($0) }
        scheduler.advance(by: 0.08)
        batcher.submit(4, for: "value") { drained.append($0) }

        #expect(drained.isEmpty)
        scheduler.advance(by: 0.01)
        #expect(drained == [["value": 4]])
    }

    @Test func cancellationAndEmptyFlushAreNoOps() {
        let scheduler = ManualDeadlineScheduler()
        let batcher = LatestWinsBatcher<String, Int>(
            quietDelay: 0.05,
            maximumDelay: 0.2,
            scheduler: scheduler.schedule
        )
        var drainCount = 0

        batcher.submit(1, for: "value") { _ in drainCount += 1 }
        batcher.cancel()
        scheduler.advance(by: 1)
        batcher.flushNow { _ in drainCount += 1 }

        #expect(drainCount == 0)
    }
}

@MainActor
private final class ManualDeadlineScheduler {
    private struct Scheduled {
        let id: Int
        let deadline: TimeInterval
        let action: @MainActor () -> Void
    }

    private var now: TimeInterval = 0
    private var nextID = 0
    private var scheduled: [Scheduled] = []
    private var cancelled: Set<Int> = []

    func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> LatestWinsBatcher<String, Int>.Cancellation {
        nextID += 1
        let id = nextID
        scheduled.append(Scheduled(id: id, deadline: now + delay, action: action))
        return { [weak self] in
            self?.cancelled.insert(id)
        }
    }

    func advance(by delta: TimeInterval) {
        now += delta
        while let next = scheduled
            .filter({ !cancelled.contains($0.id) && $0.deadline <= now })
            .min(by: { $0.deadline < $1.deadline }) {
            scheduled.removeAll { $0.id == next.id }
            next.action()
        }
    }
}
