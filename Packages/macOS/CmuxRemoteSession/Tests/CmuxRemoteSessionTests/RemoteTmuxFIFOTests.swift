import Testing

@testable import CmuxRemoteSession

@Suite struct RemoteTmuxFIFOTests {
    @Test func keepsArrayOrderThroughEveryOperation() {
        var fifo = RemoteTmuxFIFO<Int>()
        var model: [Int] = []
        var next = 0
        // A fixed, varied sequence of operations, checked against a plain array after each one.
        for step in 0..<2_000 {
            switch step % 7 {
            case 0, 1, 2:
                fifo.append(next); model.append(next); next += 1
            case 3:
                let batch = Array(next..<(next + 4)); next += 4
                fifo.append(contentsOf: batch); model.append(contentsOf: batch)
            case 4 where !model.isEmpty:
                #expect(fifo.removeFirst() == model.removeFirst())
            case 5:
                let k = min(3, model.count)
                #expect(Array(fifo.prefix(k)) == Array(model.prefix(k)))
                fifo.removeFirst(k); model.removeFirst(k)
            case 6 where model.count >= 2:
                fifo.removeLast(2); model.removeLast(2)
            default:
                break
            }
            #expect(Array(fifo) == model)
            #expect(fifo.count == model.count)
            #expect(fifo.isEmpty == model.isEmpty)
            #expect(fifo.first == model.first)
        }
        fifo.removeAll()
        #expect(fifo.isEmpty && fifo.first == nil && Array(fifo).isEmpty)
    }

    @Test func prefixLongerThanTheQueueReturnsEverything() {
        var fifo = RemoteTmuxFIFO<Int>()
        fifo.append(contentsOf: [1, 2, 3])
        fifo.removeFirst()
        #expect(Array(fifo.prefix(10)) == [2, 3])
        #expect(Array(fifo.prefix(0)).isEmpty)
    }

    /// A catch-up on a 5,000-pane session queues five commands per pane, and each reply takes
    /// one off the front while more are appended. An array would shift the remainder on every
    /// removal, about 300 million element moves here. The FIFO must copy each element a
    /// constant number of times: counted from its storage, not timed.
    @Test func aCatchUpSizedQueueCopiesEachElementAConstantNumberOfTimes() {
        let panes = 5_000
        let commandsPerPane = 5
        var fifo = RemoteTmuxFIFO<Int>()
        var appended = 0
        var copied = 0
        func removeOne() {
            let before = fifo.storage.count
            let liveAfter = fifo.count - 1
            fifo.removeFirst()
            // A compaction leaves the live elements at the front of fresh storage.
            if fifo.head == 0, fifo.storage.count < before { copied += liveAfter }
        }
        for pane in 0..<panes {
            fifo.append(contentsOf: (0..<commandsPerPane).map { pane * commandsPerPane + $0 })
            appended += commandsPerPane
            // Replies keep arriving while the batch is still being queued.
            if pane % 2 == 1 { for _ in 0..<commandsPerPane { removeOne() } }
        }
        while !fifo.isEmpty { removeOne() }
        #expect(appended == panes * commandsPerPane)
        #expect(copied <= appended, "copied \(copied) elements for \(appended) appended")
        #expect(fifo.storage.isEmpty && fifo.head == 0)
    }
}
