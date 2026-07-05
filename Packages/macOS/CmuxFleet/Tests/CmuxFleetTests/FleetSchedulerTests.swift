import CmuxFleet
import Foundation
import Testing

@Suite("FleetScheduler")
struct FleetSchedulerTests {
    @Test func filtersBlockedAndNonQueuedTasks() {
        let tasks = [
            FleetTestSupport.task(idSuffix: "blocked", isBlocked: true),
            FleetTestSupport.task(idSuffix: "running", state: .running),
            FleetTestSupport.task(idSuffix: "queued"),
        ]

        let selected = FleetScheduler(maxConcurrentAgents: 3).dispatch(tasks)

        #expect(selected.map(\.id.rawValue) == ["local:queued"])
    }

    @Test func sortsByPriorityAgeAndIdentifierWithNilPriorityLast() {
        let old = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let tasks = [
            FleetTestSupport.task(id: "local:nil", priority: nil, createdAt: old),
            FleetTestSupport.task(id: "local:p2-new", priority: 2, createdAt: newer),
            FleetTestSupport.task(id: "local:p1", priority: 1, createdAt: newer),
            FleetTestSupport.task(id: "local:p2-old-b", priority: 2, createdAt: old),
            FleetTestSupport.task(id: "local:p2-old-a", priority: 2, createdAt: old),
        ]

        let selected = FleetScheduler(maxConcurrentAgents: 10, provisioningCap: 10).dispatch(tasks)

        #expect(selected.map(\.id.rawValue) == [
            "local:p1",
            "local:p2-old-a",
            "local:p2-old-b",
            "local:p2-new",
            "local:nil",
        ])
    }

    @Test func respectsGlobalActiveCap() {
        let tasks = [
            FleetTestSupport.task(idSuffix: "active-1", state: .running),
            FleetTestSupport.task(idSuffix: "active-2", state: .needsInput),
            FleetTestSupport.task(idSuffix: "queued-1"),
            FleetTestSupport.task(idSuffix: "queued-2"),
        ]

        let selected = FleetScheduler(maxConcurrentAgents: 3, provisioningCap: 5).dispatch(tasks)

        #expect(selected.map(\.id.rawValue) == ["local:queued-1"])
    }

    @Test func respectsProvisioningCap() {
        let tasks = [
            FleetTestSupport.task(idSuffix: "provisioning", state: .provisioning),
            FleetTestSupport.task(idSuffix: "queued-1"),
            FleetTestSupport.task(idSuffix: "queued-2"),
        ]

        let selected = FleetScheduler(maxConcurrentAgents: 5, provisioningCap: 2).dispatch(tasks)

        #expect(selected.map(\.id.rawValue) == ["local:queued-1"])
    }

    @Test func retryBackoffAndStalledReserveDispatchCap() {
        let tasks = [
            FleetTestSupport.task(idSuffix: "backoff", state: .retryBackoff),
            FleetTestSupport.task(idSuffix: "stalled", state: .stalled),
            FleetTestSupport.task(idSuffix: "queued-1"),
            FleetTestSupport.task(idSuffix: "queued-2"),
        ]

        let selected = FleetScheduler(maxConcurrentAgents: 2, provisioningCap: 2).dispatch(tasks)

        #expect(selected.isEmpty)
    }

    @Test func returnsEachTaskIDAtMostOnce() {
        let duplicateA = FleetTestSupport.task(id: "local:dup", createdAt: Date(timeIntervalSince1970: 1))
        let duplicateB = FleetTestSupport.task(id: "local:dup", createdAt: Date(timeIntervalSince1970: 2))
        let unique = FleetTestSupport.task(id: "local:unique", createdAt: Date(timeIntervalSince1970: 3))

        let selected = FleetScheduler(maxConcurrentAgents: 3).dispatch([duplicateB, unique, duplicateA])

        #expect(selected.map(\.id.rawValue) == ["local:dup", "local:unique"])
    }
}
