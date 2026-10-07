import CCmuxRdFFI
import Foundation
import Testing
@testable import CmuxNextRemoteView

/// The viewer input channel through the client xcframework: events in,
/// `Input` datagrams (cmux-rd-proto layout) out, `InputAck` datagrams in.
struct RemoteRdInputTests {
    /// An `InputAck` datagram: the 16-byte header (kind 5) and `u32 applied`.
    static func ack(_ applied: UInt32) -> Data {
        var bytes: [UInt8] = [0x10, 0x05] + [UInt8](repeating: 0, count: 14)
        bytes += withUnsafeBytes(of: applied.littleEndian) { Array($0) }
        return Data(bytes)
    }

    @Test func importedEventLayoutMatchesTheRustSide() {
        #expect(MemoryLayout<CmuxRdInputEvent>.size == 48)
        #expect(Int(CMUX_RD_INPUT_MAX_TEXT) == RemoteInputEvent.maxTextBytes)
    }

    @Test func eventsBecomeOneInputDatagramWithTheWireTags() throws {
        let input = try #require(RemoteRdInput(carrier: .datagram))
        #expect(input.nextDeadlineMicros == nil)
        #expect(try input.send(.key(usage: 0x0007_0004, down: true)) == 1)
        #expect(try input.send(.button(.right, down: false)) == 2)
        #expect(input.nextDeadlineMicros == 0)
        let packets = try input.packets(nowMicros: 1_000)
        try #require(packets.count == 1)
        let bytes = [UInt8](packets[0])
        // Header: version 1, kind Input (4).
        #expect(bytes[0] == 0x10)
        #expect(bytes[1] == 0x04)
        // Payload: u32 first_seq 1, u8 count 2, key (tag 1, usage, down), button (tag 3, 3, up).
        #expect(Array(bytes[16...]) == [1, 0, 0, 0, 2, 1, 0x04, 0x00, 0x07, 0x00, 1, 3, 3, 0])
        // Nothing new: the repeat waits for the resend timer.
        #expect(input.nextDeadlineMicros == 21_000)
        #expect(try input.packets(nowMicros: 1_001).isEmpty)
    }

    @Test func anAckEndsTheRepeats() throws {
        let input = try #require(RemoteRdInput(carrier: .datagram, resendMicros: 10_000))
        try input.send(.key(usage: 0x0007_0029, down: false))
        #expect(try input.packets(nowMicros: 0).count == 1)
        #expect(try input.packets(nowMicros: 10_000).count == 1)
        try input.acknowledge(datagram: Self.ack(1))
        #expect(input.nextDeadlineMicros == nil)
        #expect(try input.packets(nowMicros: 50_000).isEmpty)
    }

    @Test func longTextIsSplitAndBadEventsAreRefused() throws {
        let input = try #require(RemoteRdInput(carrier: .stream))
        let long = String(repeating: "é", count: 300)
        #expect(throws: RemoteRdCoreError.invalid) { try input.send(.text(long)) }
        #expect(throws: RemoteRdCoreError.invalid) { try input.send(.text("")) }
        for event in RemoteInputEvent.textEvents(long) {
            try input.send(event)
        }
        let packets = try input.packets(nowMicros: 0)
        // 256 + 256 + 88 bytes of text fit one packet.
        #expect(packets.count == 1)
        // Stream carrier: each packet is one stream frame of type 2 (datagram).
        for packet in packets {
            #expect(packet.first == 2)
            #expect(packet.count <= Int(CMUX_RD_INPUT_PACKET_MAX))
        }
        // Any datagram other than an InputAck is refused without a state change.
        var feedback = [UInt8](Self.ack(3))
        feedback[1] = 7
        #expect(throws: RemoteRdCoreError.invalid) { try input.acknowledge(datagram: Data(feedback)) }
        #expect(input.nextDeadlineMicros != nil)
    }
}
