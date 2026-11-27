import Foundation
import Testing

@testable import CmuxMobileTerminalKit

@Suite("TerminalArrowRepeatService")
struct TerminalArrowRepeatServiceTests {
    @Test("each direction yields its exact VT escape sequence")
    func directionBytes() {
        let expected: [(TerminalArrowRepeatService.Direction, [UInt8])] = [
            (.upArrow, [0x1B, 0x5B, 0x41]),
            (.downArrow, [0x1B, 0x5B, 0x42]),
            (.leftArrow, [0x1B, 0x5B, 0x44]),
            (.rightArrow, [0x1B, 0x5B, 0x43]),
        ]
        for (direction, bytes) in expected {
            #expect(Array(direction.bytes) == bytes)
        }
    }

    @Test("repeats fire one immediate emission then one per interval")
    func repeatsCadence() async {
        let service = TerminalArrowRepeatService()
        let stream = service.repeats(of: .rightArrow, every: .milliseconds(5), clock: ContinuousClock())

        var received: [[UInt8]] = []
        for await bytes in stream {
            received.append(Array(bytes))
            if received.count >= 3 { break }
        }

        #expect(received.count == 3)
        for bytes in received {
            #expect(bytes == [0x1B, 0x5B, 0x43])
        }
    }

    @Test("breaking out of the consumer terminates the stream cadence")
    func consumerBreakStops() async {
        let service = TerminalArrowRepeatService()
        let stream = service.repeats(of: .upArrow, every: .milliseconds(5), clock: ContinuousClock())

        // Consume exactly one (the immediate emission) and break; onTermination
        // cancels the producer task so no further cadence runs.
        var received = 0
        for await _ in stream {
            received += 1
            break
        }
        #expect(received == 1)
    }
}
