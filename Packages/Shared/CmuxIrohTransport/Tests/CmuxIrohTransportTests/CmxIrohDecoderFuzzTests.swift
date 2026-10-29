import CMUXMobileCore
import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Crash program phase 3 (plans/cmux-next/crash-elimination.md section 7): the
/// Iroh decoders read bytes and text from a peer, a relay or the LAN. Any input
/// gives a value or a typed error; never a trap. Seeded property tests on
/// CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS).
@Suite struct CmxIrohDecoderFuzzTests {
    static func mutate(_ data: Data, _ rng: inout FuzzRNG) -> Data {
        FuzzMutator().mutate(data, using: &rng)
    }

    /// One input of a decoder, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(5) {
        case 0:
            let codec = try CmxIrohStreamHeaderCodec()
            let headers = try streamHeaders()
            try streamHeader(encoded: codec.encode(headers[rng.below(headers.count)]), codec: codec, &rng)
        case 1: terminalOutputEnvelope(try terminalOutputSample(), &rng)
        case 2: lanTXTRecordAndAddress(try lanTXTSample(), &rng)
        case 3: admissionAck(&rng)
        default: _ = try? CmxIrohStreamHeaderCodec().decodePrefix(rng.bytes(256))
        }
    }

    static func streamHeaders() throws -> [CmxIrohStreamHeader] {
        [
            try CmxIrohStreamHeader(lane: .control, credential: .pairGrant("e30.e30.AA")),
            try CmxIrohStreamHeader(lane: .control, credential: .offlinePairing(
                endpointAttestation: "eyJraWQiOiJrMSJ9.e30.AA",
                invitationID: CmxIrohResourceID("invite:42"),
                proof: Data(repeating: 0x5a, count: 32)
            )),
        ]
    }

    static func streamHeader(encoded: Data, codec: CmxIrohStreamHeaderCodec, _ rng: inout FuzzRNG) {
        _ = try? codec.decodePrefix(mutate(encoded, &rng))
        _ = try? codec.decodePrefix(rng.bytes(64))
    }

    static func terminalOutputSample() throws -> CmxIrohTerminalOutputEnvelope {
        try CmxIrohTerminalOutputEnvelope(
            kind: .chunk, retainedBaseSequence: 45, sequence: 45, currentSequence: 48, payload: Data("def".utf8)
        )
    }

    static func terminalOutputEnvelope(_ envelope: CmxIrohTerminalOutputEnvelope, _ rng: inout FuzzRNG) {
        let codec = CmxIrohTerminalOutputEnvelopeCodec()
        let encoded = codec.encode(envelope)
        _ = try? codec.decodePrefix(mutate(encoded, &rng))
        _ = try? codec.decodePrefix(rng.bytes(80))
        var decoder = CmxIrohTerminalOutputEnvelopeDecoder()
        _ = try? decoder.append(mutate(encoded + encoded, &rng))
    }

    static let addressSeeds = ["192.168.1.10:50906", "[fd00::1]:4000", "[", "]:", "[]:1", ":", "1.2.3.4", "0.0.0.0:1", "[::]:1"]

    static func lanTXTSample() throws -> Data {
        try CmxIrohLANTXTRecord(
            epoch: 6_000_000,
            addresses: [try CmxIrohLANSocketAddress("192.168.1.10:50906")]
        ).encoded()
    }

    static func lanTXTRecordAndAddress(_ valid: Data, _ rng: inout FuzzRNG) {
        _ = try? CmxIrohLANTXTRecord(encoded: mutate(valid, &rng))
        _ = try? CmxIrohLANTXTRecord(encoded: rng.bytes(40))
        let seed = Data(addressSeeds[rng.below(addressSeeds.count)].utf8)
        _ = try? CmxIrohLANSocketAddress(String(decoding: mutate(seed, &rng), as: UTF8.self))
    }

    static func admissionAck(_ rng: inout FuzzRNG) {
        _ = try? CmxIrohAdmissionAckCodec().decodePrefix(rng.bytes(24))
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
        let codec = try CmxIrohStreamHeaderCodec()
        for (index, header) in try Self.streamHeaders().enumerated() {
            let encoded = try codec.encode(header)
            #expect(try codec.decodePrefix(encoded).header == header)
            let run = try FuzzRun("CmxIrohDecoder.streamHeader\(index)", seed: 0x71 &+ UInt64(index), iterations: 1_500)
            try run.forEach { rng in Self.streamHeader(encoded: encoded, codec: codec, &rng) }
        }
    }

    @Test func terminalOutputEnvelopesDecodeOrThrowForAnyBytes() throws {
        let envelope = try Self.terminalOutputSample()
        let codec = CmxIrohTerminalOutputEnvelopeCodec()
        #expect(try codec.decodePrefix(codec.encode(envelope)) == envelope)
        try FuzzRun("CmxIrohDecoder.terminalOutput", seed: 0x72, iterations: 2_000).forEach { rng in
            Self.terminalOutputEnvelope(envelope, &rng)
        }
    }

    @Test func lanTXTRecordsAndSocketAddressesDecodeOrThrowForAnyInput() throws {
        let valid = try Self.lanTXTSample()
        try FuzzRun("CmxIrohDecoder.lanTXT", seed: 0x73, iterations: 2_000).forEach { rng in
            Self.lanTXTRecordAndAddress(valid, &rng)
        }
        #expect(try CmxIrohLANSocketAddress("[fd00::1]:4000").port == 4000)
    }

    @Test func admissionAcknowledgementsDecodeOrThrowForAnyBytes() throws {
        try FuzzRun("CmxIrohDecoder.admissionAck", seed: 0x74, iterations: 2_000).forEach { rng in
            Self.admissionAck(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("CmxIrohDecoder.oneInput", seed: 0x75, iterations: 512)
        // Choice tapes: one per branch of `oneInput`, and for the raw-bytes branch (4) a tape whose
        // byte count and bytes are a real encoded stream header, so the decoder starts from one.
        let codec = try CmxIrohStreamHeaderCodec()
        let branches: [[UInt8]] = [[0, 0], [0, 1], [1], [2], [3], [4]]
        let encodedHeaders = try Self.streamHeaders().map { try codec.encode($0) }.filter { $0.count < 256 }
        let tapes = branches.map { Data($0) } + encodedHeaders.map { Data([4, UInt8($0.count)]) + $0 }
        try run.forEachInput(run.corpus(seeds: tapes), Self.oneInput)
    }
}
