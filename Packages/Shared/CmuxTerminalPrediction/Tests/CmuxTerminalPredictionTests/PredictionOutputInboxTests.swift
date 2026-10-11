import Foundation
import Testing
@testable import CmuxTerminalPrediction

/// An inbox that already accepts `surfaces`.
private func inbox(accepting surfaces: UUID...) -> PredictionOutputInbox {
    let inbox = PredictionOutputInbox()
    for surface in surfaces { inbox.accept(surfaceID: surface) }
    return inbox
}

struct PredictionOutputInboxTests {
    @Test func theFirstDepositOwnsSchedulingAndLaterOnesDoNot() {
        let surface = UUID()
        let other = UUID()
        let inbox = inbox(accepting: surface, other)

        #expect(inbox.deposit(surfaceID: surface, bytes: [0x61], at: .zero))
        #expect(!inbox.deposit(surfaceID: surface, bytes: [0x62], at: .milliseconds(1)))
        #expect(!inbox.deposit(surfaceID: other, bytes: [0x63], at: .milliseconds(2)))
    }

    @Test func drainingReArmsScheduling() {
        let surface = UUID()
        let inbox = inbox(accepting: surface)

        #expect(inbox.deposit(surfaceID: surface, bytes: [0x61], at: .zero))
        _ = inbox.drain()
        #expect(inbox.deposit(surfaceID: surface, bytes: [0x62], at: .milliseconds(1)))
    }

    @Test func chunksKeepTheirArrivalOrderAndInstants() {
        let surface = UUID()
        let inbox = inbox(accepting: surface)

        _ = inbox.deposit(surfaceID: surface, bytes: [0x61], at: .milliseconds(1))
        _ = inbox.deposit(surfaceID: surface, bytes: [0x62, 0x63], at: .milliseconds(9))

        let drained = inbox.drain()
        #expect(drained[surface] == [
            PredictionOutputBatch(instant: .milliseconds(1), bytes: [0x61]),
            PredictionOutputBatch(instant: .milliseconds(9), bytes: [0x62, 0x63]),
        ])
    }

    @Test func surfacesDoNotMix() {
        let first = UUID()
        let second = UUID()
        let inbox = inbox(accepting: first, second)

        _ = inbox.deposit(surfaceID: first, bytes: [0x61], at: .zero)
        _ = inbox.deposit(surfaceID: second, bytes: [0x62], at: .zero)

        let drained = inbox.drain()
        #expect(drained[first]?.flatMap(\.bytes) == [0x61])
        #expect(drained[second]?.flatMap(\.bytes) == [0x62])
    }

    @Test func drainingLeavesNothingBehind() {
        let surface = UUID()
        let inbox = inbox(accepting: surface)
        _ = inbox.deposit(surfaceID: surface, bytes: [0x61], at: .zero)

        _ = inbox.drain()
        #expect(inbox.drain().isEmpty)
    }

    @Test func forgettingASurfaceKeepsTheOthers() {
        let gone = UUID()
        let kept = UUID()
        let inbox = inbox(accepting: gone, kept)
        _ = inbox.deposit(surfaceID: gone, bytes: [0x61], at: .zero)
        _ = inbox.deposit(surfaceID: kept, bytes: [0x62], at: .zero)

        inbox.forget(surfaceID: gone)

        let drained = inbox.drain()
        #expect(drained[gone] == nil)
        #expect(drained[kept]?.count == 1)
    }

    @Test func aSurfaceThatWasNeverAcceptedDepositsNothing() {
        // Local terminals register too. Their output must not be copied or
        // hop to the main actor just because prediction is turned on.
        let inbox = PredictionOutputInbox()

        #expect(!inbox.deposit(surfaceID: UUID(), bytes: [0x61], at: .zero))
        #expect(inbox.drain().isEmpty)
    }

    @Test func aForgottenSurfaceStopsDepositingUntilAcceptedAgain() {
        let surface = UUID()
        let inbox = inbox(accepting: surface)

        inbox.forget(surfaceID: surface)
        #expect(!inbox.deposit(surfaceID: surface, bytes: [0x61], at: .zero))

        inbox.accept(surfaceID: surface)
        #expect(inbox.deposit(surfaceID: surface, bytes: [0x62], at: .zero))
        #expect(inbox.drain()[surface]?.flatMap(\.bytes) == [0x62])
    }

    @Test func forgettingEverySurfaceDropsBufferedOutput() {
        let first = UUID()
        let second = UUID()
        let inbox = inbox(accepting: first, second)
        _ = inbox.deposit(surfaceID: first, bytes: [0x61], at: .zero)

        inbox.forgetAll()

        #expect(inbox.drain().isEmpty)
        #expect(!inbox.deposit(surfaceID: second, bytes: [0x62], at: .zero))
    }

    @Test func concurrentDepositsScheduleExactlyOneDrain() {
        let surface = UUID()
        let inbox = inbox(accepting: surface)
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

    @Test func aSurfaceThatOutrunsTheDrainKeepsOnlyItsNewestOutput() {
        let surface = UUID()
        let inbox = PredictionOutputInbox(maximumBufferedBytes: 8)
        inbox.accept(surfaceID: surface)
        _ = inbox.deposit(surfaceID: surface, bytes: Array("abcdef".utf8), at: .milliseconds(1))
        _ = inbox.deposit(surfaceID: surface, bytes: Array("ghijk".utf8), at: .milliseconds(2))
        let drained = inbox.drain()[surface] ?? []
        #expect(drained.map(\.bytes) == [Array("ghijk".utf8)])
        #expect(drained.map(\.followsDroppedOutput) == [true])

        _ = inbox.deposit(surfaceID: surface, bytes: Array("xy".utf8), at: .milliseconds(3))
        #expect(inbox.drain()[surface]?.map(\.followsDroppedOutput) == [false])
    }
}
