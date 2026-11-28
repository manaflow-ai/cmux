public import Foundation

/// Binary framing for sequence-aware terminal-output envelopes.
public struct CmxIrohTerminalOutputEnvelopeCodec: Sendable {
    public enum DecodeError: Error, Equatable, Sendable {
        case incompleteFrame
        case invalidMagic
        case unsupportedVersion(UInt8)
        case invalidKind(UInt8)
        case invalidReservedBits(UInt16)
        case payloadTooLarge(actual: Int, maximum: Int)
    }

    public static let headerByteCount = 36

    private static let magic = Data("CMXT".utf8)
    private static let version: UInt8 = 1

    public init() {}

    public func encode(_ envelope: CmxIrohTerminalOutputEnvelope) -> Data {
        var frame = Self.magic
        frame.append(Self.version)
        frame.append(envelope.kind.rawValue)
        Self.append(UInt16.zero, to: &frame)
        Self.append(envelope.retainedBaseSequence, to: &frame)
        Self.append(envelope.sequence, to: &frame)
        Self.append(envelope.currentSequence, to: &frame)
        // The envelope initializers bound the payload to 256 KiB, far below UInt32.max.
        Self.append(UInt32(clamping: envelope.payload.count), to: &frame)
        frame.append(envelope.payload)
        return frame
    }

    public func decodePrefix(_ data: Data) throws -> CmxIrohTerminalOutputEnvelope {
        var reader = WireByteReader(data)
        guard data.count >= Self.headerByteCount,
              let magic = reader.bytes(Self.magic.count),
              let version = reader.byte(),
              let rawKind = reader.byte(),
              let reserved = reader.bigEndian(UInt16.self),
              let retainedBaseSequence = reader.bigEndian(UInt64.self),
              let sequence = reader.bigEndian(UInt64.self),
              let currentSequence = reader.bigEndian(UInt64.self),
              let payloadLength = reader.bigEndian(UInt32.self) else {
            throw DecodeError.incompleteFrame
        }
        guard magic == Self.magic else {
            throw DecodeError.invalidMagic
        }
        guard version == Self.version else {
            throw DecodeError.unsupportedVersion(version)
        }
        guard let kind = CmxIrohTerminalOutputEnvelope.Kind(rawValue: rawKind) else {
            throw DecodeError.invalidKind(rawKind)
        }
        guard reserved == 0 else {
            throw DecodeError.invalidReservedBits(reserved)
        }
        let payloadByteCount = Int(clamping: payloadLength)
        guard payloadByteCount <= CmxIrohTerminalOutputEnvelope.maximumPayloadByteCount else {
            throw DecodeError.payloadTooLarge(
                actual: payloadByteCount,
                maximum: CmxIrohTerminalOutputEnvelope.maximumPayloadByteCount
            )
        }
        guard let payload = reader.bytes(payloadByteCount) else {
            throw DecodeError.incompleteFrame
        }
        return try CmxIrohTerminalOutputEnvelope(
            kind: kind,
            retainedBaseSequence: retainedBaseSequence,
            sequence: sequence,
            currentSequence: currentSequence,
            payload: payload
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
