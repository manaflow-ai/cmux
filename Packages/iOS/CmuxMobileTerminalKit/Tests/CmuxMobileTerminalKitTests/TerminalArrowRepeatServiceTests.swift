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

    @Test("byte repeats fire one per interval after the initial delay, repeating the exact bytes")
    func byteRepeatsCadence() async {
        // The hardware-key hold path: the press site already sent the first
        // keystroke synchronously, so this stream stays quiet for the initial
        // delay and then re-emits the SAME captured bytes every interval. ESC b
        // (Option/Ctrl+Left → backward-word) stands in for a non-arrow payload.
        let service = TerminalArrowRepeatService()
        let bytes = Data([0x1B, 0x62])
        let stream = service.repeats(
            of: bytes,
            initialDelay: .milliseconds(5),
            every: .milliseconds(5),
            clock: ContinuousClock()
        )

        var received: [[UInt8]] = []
        for await emitted in stream {
            received.append(Array(emitted))
            if received.count >= 3 { break }
        }

        #expect(received.count == 3)
        for emitted in received {
            #expect(emitted == [0x1B, 0x62])
        }
    }

    @Test("breaking out of the byte-repeat consumer terminates the cadence")
    func byteRepeatConsumerBreakStops() async {
        let service = TerminalArrowRepeatService()
        let stream = service.repeats(
            of: Data([0x03]),  // Ctrl-C
            initialDelay: .milliseconds(1),
            every: .milliseconds(1),
            clock: ContinuousClock()
        )

        // Consume the first post-delay emission and break; onTermination cancels
        // the producer task so no further cadence runs.
        var received = 0
        for await _ in stream {
            received += 1
            break
        }
        #expect(received == 1)
    }
}
