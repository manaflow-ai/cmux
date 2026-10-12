import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Crash program phase 3 (plans/cmux-next/crash-elimination.md section 7): the
/// Iroh decoders read bytes and text from a peer, a relay or the LAN. Any input
/// gives a value or a typed error; never a trap.
@Suite struct CmxIrohDecoderFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func bytes(_ limit: Int) -> Data {
            Data((0..<below(limit)).map { _ in UInt8(truncatingIfNeeded: next()) })
        }
        mutating func mutate(_ data: Data) -> Data {
            var bytes = [UInt8](data)
            for _ in 0..<(1 + below(4)) {
                switch below(4) {
                case 0 where !bytes.isEmpty: bytes[below(bytes.count)] = UInt8(truncatingIfNeeded: next())
                case 1 where !bytes.isEmpty: bytes.removeSubrange(below(bytes.count)...)
                case 2: bytes.insert(UInt8(truncatingIfNeeded: next()), at: below(bytes.count + 1))
                default: bytes += bytes.prefix(below(bytes.count + 1))
                }
            }
            return Data(bytes)
        }
    }

    /// TimeInterval(Int64.max) rounds up to 2^63, so the old range check let the
    /// last representable timestamp through to Int64(_:), which trapped.
    @Test func rendezvousEpochRefusesTimestampsPastInt64() throws {
        let interval = CmxIrohLANRendezvousAliasGenerator.rotationInterval
        for seconds in [TimeInterval(Int64.max) * interval, .infinity, .nan, -1] {
            #expect(throws: CmxIrohLANRendezvousAliasError.self) {
                try CmxIrohLANRendezvousAliasGenerator.epoch(for: Date(timeIntervalSince1970: seconds))
            }
        }
        #expect(try CmxIrohLANRendezvousAliasGenerator.epoch(for: Date(timeIntervalSince1970: interval * 3)) == 3)
    }

    @Test func streamHeadersDecodeOrThrowForAnyBytes() throws {
        var rng = Rng(state: 0x71)
        let codec = try CmxIrohStreamHeaderCodec()
        let headers = [
            try CmxIrohStreamHeader(lane: .control, credential: .pairGrant("e30.e30.AA")),
            try CmxIrohStreamHeader(lane: .control, credential: .offlinePairing(
                endpointAttestation: "eyJraWQiOiJrMSJ9.e30.AA",
                invitationID: CmxIrohResourceID("invite:42"),
                proof: Data(repeating: 0x5a, count: 32)
            )),
        ]
        for header in headers {
            let encoded = try codec.encode(header)
            #expect(try codec.decodePrefix(encoded).header == header)
            for _ in 0..<1_500 {
                _ = try? codec.decodePrefix(rng.mutate(encoded))
                _ = try? codec.decodePrefix(rng.bytes(64))
            }
        }
    }

    @Test func terminalOutputEnvelopesDecodeOrThrowForAnyBytes() throws {
        var rng = Rng(state: 0x72)
        let codec = CmxIrohTerminalOutputEnvelopeCodec()
        let envelope = try CmxIrohTerminalOutputEnvelope(
            kind: .chunk, retainedBaseSequence: 45, sequence: 45, currentSequence: 48, payload: Data("def".utf8)
        )
        let encoded = codec.encode(envelope)
        #expect(try codec.decodePrefix(encoded) == envelope)
        for _ in 0..<2_000 {
            _ = try? codec.decodePrefix(rng.mutate(encoded))
            _ = try? codec.decodePrefix(rng.bytes(80))
            var decoder = CmxIrohTerminalOutputEnvelopeDecoder()
            _ = try? decoder.append(rng.mutate(encoded + encoded))
        }
    }

    @Test func lanTXTRecordsAndSocketAddressesDecodeOrThrowForAnyInput() throws {
        var rng = Rng(state: 0x73)
        let valid = try CmxIrohLANTXTRecord(
            epoch: 6_000_000,
            addresses: [try CmxIrohLANSocketAddress("192.168.1.10:50906")]
        ).encoded()
        let seeds = ["192.168.1.10:50906", "[fd00::1]:4000", "[", "]:", "[]:1", ":", "1.2.3.4", "0.0.0.0:1", "[::]:1"]
        for _ in 0..<2_000 {
            _ = try? CmxIrohLANTXTRecord(encoded: rng.mutate(valid))
            _ = try? CmxIrohLANTXTRecord(encoded: rng.bytes(40))
            let seed = Data(seeds[rng.below(seeds.count)].utf8)
            _ = try? CmxIrohLANSocketAddress(String(decoding: rng.mutate(seed), as: UTF8.self))
        }
        #expect(try CmxIrohLANSocketAddress("[fd00::1]:4000").port == 4000)
    }

    @Test func admissionAcknowledgementsDecodeOrThrowForAnyBytes() {
        var rng = Rng(state: 0x74)
        for _ in 0..<2_000 {
            _ = try? CmxIrohAdmissionAckCodec().decodePrefix(rng.bytes(24))
        }
    }
}
