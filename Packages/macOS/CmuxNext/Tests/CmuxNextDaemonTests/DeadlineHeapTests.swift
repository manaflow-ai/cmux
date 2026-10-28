import CmuxFuzzSupport
import Testing
@testable import CmuxNextDaemon

/// ``DeadlineHeap`` and ``PendingRequests`` against plain models under seeded random operations.
@Suite struct DeadlineHeapTests {
    /// Inserts (new and replacing), removals by id and due pops agree with a sorted model; equal deadlines
    /// come out in id order.
    @Test func randomOperationsMatchASortedModel() throws {
        var rng = FuzzRNG(seed: 0x0905_0090_0001)
        for _ in 0..<200 {
            var heap = DeadlineHeap()
            var model: [UInt64: Duration] = [:]
            var now = Duration.zero
            for _ in 0..<200 {
                let id = UInt64(rng.below(40))
                switch rng.below(4) {
                case 0, 1:
                    let at = now + .milliseconds(rng.below(50))
                    heap.insert(id: id, DeadlineHeap.Deadline(at: at, timeout: .seconds(1)))
                    model[id] = at
                case 2:
                    #expect(heap.remove(id: id)?.deadline.at == model.removeValue(forKey: id))
                default:
                    now += .milliseconds(rng.below(20))
                    let due = model.filter { $0.value <= now }.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
                    var popped: [UInt64] = []
                    while let entry = heap.popDue(at: now) { popped.append(entry.id) }
                    #expect(popped == due.map(\.key))
                    for (id, _) in due { model[id] = nil }
                }
                #expect(heap.count == model.count)
                let earliest = model.min { ($0.value, $0.key) < ($1.value, $1.key) }
                #expect(heap.first?.id == earliest?.key && heap.first?.deadline.at == earliest?.value)
            }
        }
    }

    /// Appends, removals by id, replacements and oldest lookups agree with an ordered model, and the ring
    /// never holds much more than the waiting ids, even while the oldest request never gets its reply.
    @Test func pendingRequestsKeepSendOrderInBoundedSpace() throws {
        var rng = FuzzRNG(seed: 0x0905_0090_0002)
        var pending = PendingRequests()
        var model: [UInt64] = []
        let stuck = PendingRequest(waiter: .expired(cmd: "stuck"), sent: nil)
        pending.append(stuck, id: 0)
        model.append(0)
        for id in UInt64(1)...20_000 {
            pending.append(PendingRequest(waiter: .discard(cmd: "c\(id)", onError: nil), sent: nil), id: id)
            model.append(id)
            if rng.oneIn(3), let index = model.indices.dropFirst().randomElement(using: &rng) {
                #expect(pending.remove(id: model[index]) != nil)
                model.remove(at: index)
            }
            if model.count > 8 {
                // Answer everything but the stuck request and the newest few, in a random order.
                let answered = model[1..<(model.count - 4)]
                for answer in answered.shuffled(using: &rng) { #expect(pending.remove(id: answer) != nil) }
                model.removeSubrange(1..<(model.count - 4))
            }
            #expect(pending.oldestID() == model.first)
            #expect(pending.count == model.count)
        }
        #expect(pending[0]?.waiter.cmd == "stuck")
        pending.replace(id: 0, with: PendingRequest(waiter: .expired(cmd: "replaced"), sent: nil))
        #expect(pending.oldestID() == 0)
        #expect(pending.removeAllInSendOrder().map(\.waiter.cmd) == ["replaced"] + model.dropFirst().map { "c\($0)" })
        #expect(pending.isEmpty && pending.oldestID() == nil)
    }

    /// The ring stays within twice the waiting ids plus its slack while one request never gets its reply.
    @Test func theRingIsCompactedAroundAStuckRequest() {
        var pending = PendingRequests()
        pending.append(PendingRequest(waiter: .expired(cmd: "stuck"), sent: nil), id: 0)
        for id in UInt64(1)...100_000 {
            pending.append(PendingRequest(waiter: .expired(cmd: "x"), sent: nil), id: id)
            _ = pending.remove(id: id)
        }
        #expect(pending.ringCount <= 2 * pending.count + 33)
        #expect(pending.oldestID() == 0)
    }
}
