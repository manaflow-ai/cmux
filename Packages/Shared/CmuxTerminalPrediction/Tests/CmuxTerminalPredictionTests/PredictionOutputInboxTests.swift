import Foundation
import Testing
@testable import CmuxTerminalPrediction

struct PredictionOutputInboxTests {
    @Test func theFirstDepositOwnsSchedulingAndLaterOnesDoNot() {
        let inbox = PredictionOutputInbox()
        let surface = UUID()

        #expect(inbox.deposit(surfaceID: surface, bytes: [0x61], at: .zero))
        #expect(!inbox.deposit(surfaceID: surface, bytes: [0x62], at: .milliseconds(1)))
        #expect(!inbox.deposit(surfaceID: UUID(), bytes: [0x63], at: .milliseconds(2)))
    }

    @Test func drainingReArmsScheduling() {
        let inbox = PredictionOutputInbox()
        let surface = UUID()

        #expect(inbox.deposit(surfaceID: surface, bytes: [0x61], at: .zero))
        _ = inbox.drain()
        #expect(inbox.deposit(surfaceID: surface, bytes: [0x62], at: .milliseconds(1)))
    }

    @Test func chunksKeepTheirArrivalOrderAndInstants() {
        let inbox = PredictionOutputInbox()
        let surface = UUID()

        _ = inbox.deposit(surfaceID: surface, bytes: [0x61], at: .milliseconds(1))
        _ = inbox.deposit(surfaceID: surface, bytes: [0x62, 0x63], at: .milliseconds(9))

        let drained = inbox.drain()
        #expect(drained[surface] == [
            PredictionOutputBatch(instant: .milliseconds(1), bytes: [0x61]),
            PredictionOutputBatch(instant: .milliseconds(9), bytes: [0x62, 0x63]),
        ])
    }

    @Test func surfacesDoNotMix() {
        let inbox = PredictionOutputInbox()
        let first = UUID()
        let second = UUID()

        _ = inbox.deposit(surfaceID: first, bytes: [0x61], at: .zero)
        _ = inbox.deposit(surfaceID: second, bytes: [0x62], at: .zero)

        let drained = inbox.drain()
        #expect(drained[first]?.flatMap(\.bytes) == [0x61])
        #expect(drained[second]?.flatMap(\.bytes) == [0x62])
    }

    @Test func drainingLeavesNothingBehind() {
        let inbox = PredictionOutputInbox()
        _ = inbox.deposit(surfaceID: UUID(), bytes: [0x61], at: .zero)

        _ = inbox.drain()
        #expect(inbox.drain().isEmpty)
    }

    @Test func forgettingASurfaceKeepsTheOthers() {
        let inbox = PredictionOutputInbox()
        let gone = UUID()
        let kept = UUID()
        _ = inbox.deposit(surfaceID: gone, bytes: [0x61], at: .zero)
        _ = inbox.deposit(surfaceID: kept, bytes: [0x62], at: .zero)

        inbox.forget(surfaceID: gone)

        let drained = inbox.drain()
        #expect(drained[gone] == nil)
        #expect(drained[kept]?.count == 1)
    }

    @Test func concurrentDepositsScheduleExactlyOneDrain() {
        let inbox = PredictionOutputInbox()
        let surface = UUID()
        let scheduled = NSLock()
        nonisolated(unsafe) var scheduleCount = 0

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            if inbox.deposit(surfaceID: surface, bytes: [UInt8(index % 256)], at: .zero) {
                scheduled.lock()
                scheduleCount += 1
                scheduled.unlock()
            }
        }

        #expect(scheduleCount == 1)
        #expect(inbox.drain()[surface]?.count == 500)
    }
}
