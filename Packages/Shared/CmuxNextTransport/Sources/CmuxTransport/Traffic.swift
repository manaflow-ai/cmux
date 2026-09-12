import Foundation
import CryptoKit

/// Terminal-shaped synthetic traffic (harness spec 1.4): deterministic,
/// sequence-numbered, checksummed. Determinism matters so any run can be
/// reproduced exactly; no randomness APIs are used.
public struct TerminalTraffic: Sendable {
    /// Creates the stateless TerminalTraffic operation value.
    public init() {}

    /// Deterministic pseudo-random chunk derived from (seed, seq).
    /// - Parameters:
    ///   - seq: Sequence number carried by the frame.
    ///   - size: Nonnegative payload byte count.
    ///   - seed: Reproducible generator seed.
    /// - Returns: A data frame containing the payload and its SHA-256 checksum.
    public func chunk(seq: Int64, size: Int, seed: UInt64) -> Frame {
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
    /// Number of structurally valid data frames observed, including checksum failures.
    public private(set) var received = 0
    /// Sequence expected after the most recently accepted frame, initially zero.
    public private(set) var expectedSeq: Int64 = 0
    /// First observed sequence discontinuity, including duplicates, or nil.
    public private(set) var firstGap: (expected: Int64, got: Int64)?
    /// Number of structurally valid frames whose digest did not match their bytes.
    public private(set) var checksumFailures = 0
    /// Number of frames rejected for missing fields, wrong type, or invalid sequence.
    public private(set) var malformedFrames = 0

    /// Starts validation at sequence zero with no observations.
    public init() {}

    /// Whether all observed frames were ordered and valid; also true before any input.
    public var isClean: Bool {
        firstGap == nil && checksumFailures == 0 && malformedFrames == 0
    }

    /// Records sequence and checksum results without throwing on corrupt traffic.
    /// - Parameter frame: Next frame in receive order.
    public mutating func ingest(_ frame: Frame) {
        guard frame.type == FrameTypePolicy.dataChunk,
            let seq = frame.payload["seq"]?.intValue,
            let data = frame.payload["data"]?.dataValue,
            let declaredDigest = frame.payload["sha256"]?.stringValue
        else {
            malformedFrames += 1
            return
        }
        guard seq < Int64.max else {
            malformedFrames += 1
            return
        }
        received += 1
        if seq != expectedSeq, firstGap == nil {
            firstGap = (expected: expectedSeq, got: seq)
        }
        expectedSeq = seq + 1
        let digest = HexEncoding().lowercase(SHA256.hash(data: data))
        if digest != declaredDigest {
            checksumFailures += 1
        }
    }
}
