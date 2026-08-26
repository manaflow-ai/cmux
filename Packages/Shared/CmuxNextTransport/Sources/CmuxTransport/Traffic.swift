import Foundation
import CryptoKit

/// Terminal-shaped synthetic traffic (harness spec 1.4): deterministic,
/// sequence-numbered, checksummed. Determinism matters so any run can be
/// reproduced exactly; no randomness APIs are used.
public enum TerminalTraffic {
    /// Deterministic pseudo-random chunk derived from (seed, seq).
    public static func chunk(seq: Int64, size: Int, seed: UInt64) -> Frame {
        var bytes = Data(capacity: size)
        var state = seed &+ UInt64(bitPattern: seq) &* 0x9E37_79B9_7F4A_7C15
        for _ in 0..<size {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return Frame.dataChunk(seq: seq, data: bytes)
    }
}

/// Consumes data chunks and reports the FIRST gap, duplicate, or checksum
/// mismatch with exact positions. A clean validator after a run is what
/// "ordered and lossless" (5.1) means in practice.
public struct TrafficValidator: Sendable {
    public private(set) var received = 0
    public private(set) var expectedSeq: Int64 = 0
    public private(set) var firstGap: (expected: Int64, got: Int64)?
    public private(set) var checksumFailures = 0
    public private(set) var malformedFrames = 0

    public init() {}

    public var isClean: Bool {
        firstGap == nil && checksumFailures == 0 && malformedFrames == 0
    }

    public mutating func ingest(_ frame: Frame) {
        guard frame.type == FrameTypes.dataChunk,
            let seq = frame.payload["seq"]?.intValue,
            let data = frame.payload["data"]?.dataValue,
            let declaredDigest = frame.payload["sha256"]?.stringValue
        else {
            malformedFrames += 1
            return
        }
        received += 1
        if seq != expectedSeq, firstGap == nil {
            firstGap = (expected: expectedSeq, got: seq)
        }
        expectedSeq = seq + 1
        let digest = HexEncoding.lowercase(SHA256.hash(data: data))
        if digest != declaredDigest {
            checksumFailures += 1
        }
    }
}
