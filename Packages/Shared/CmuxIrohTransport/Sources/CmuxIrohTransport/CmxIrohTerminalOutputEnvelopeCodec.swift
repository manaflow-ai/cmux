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
        Self.append(UInt32(envelope.payload.count), to: &frame)
        frame.append(envelope.payload)
        return frame
    }

    public func decodePrefix(_ data: Data) throws -> CmxIrohTerminalOutputEnvelope {
        guard data.count >= Self.headerByteCount else {
            throw DecodeError.incompleteFrame
        }
        var offset = 0
        guard Self.readData(byteCount: Self.magic.count, from: data, offset: &offset) == Self.magic else {
            throw DecodeError.invalidMagic
        }
        let version = Self.readUInt8(from: data, offset: &offset)
        guard version == Self.version else {
            throw DecodeError.unsupportedVersion(version)
        }
        let rawKind = Self.readUInt8(from: data, offset: &offset)
        guard let kind = CmxIrohTerminalOutputEnvelope.Kind(rawValue: rawKind) else {
            throw DecodeError.invalidKind(rawKind)
        }
        let reserved = Self.readUInt16(from: data, offset: &offset)
        guard reserved == 0 else {
            throw DecodeError.invalidReservedBits(reserved)
        }
        let retainedBaseSequence = Self.readUInt64(from: data, offset: &offset)
        let sequence = Self.readUInt64(from: data, offset: &offset)
        let currentSequence = Self.readUInt64(from: data, offset: &offset)
        let payloadByteCount = Int(Self.readUInt32(from: data, offset: &offset))
        guard payloadByteCount <= CmxIrohTerminalOutputEnvelope.maximumPayloadByteCount else {
            throw DecodeError.payloadTooLarge(
                actual: payloadByteCount,
                maximum: CmxIrohTerminalOutputEnvelope.maximumPayloadByteCount
            )
        }
        guard data.count >= Self.headerByteCount + payloadByteCount else {
            throw DecodeError.incompleteFrame
        }
        let payload = Self.readData(byteCount: payloadByteCount, from: data, offset: &offset)
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

    private static func readUInt8(from data: Data, offset: inout Int) -> UInt8 {
        let value = data[data.index(data.startIndex, offsetBy: offset)]
        offset += 1
        return value
    }

    private static func readUInt16(from data: Data, offset: inout Int) -> UInt16 {
        readInteger(byteCount: 2, from: data, offset: &offset)
    }

    private static func readUInt32(from data: Data, offset: inout Int) -> UInt32 {
        readInteger(byteCount: 4, from: data, offset: &offset)
    }

    private static func readUInt64(from data: Data, offset: inout Int) -> UInt64 {
        readInteger(byteCount: 8, from: data, offset: &offset)
    }

    private static func readInteger<T: FixedWidthInteger>(
        byteCount: Int,
        from data: Data,
        offset: inout Int
    ) -> T {
        readData(byteCount: byteCount, from: data, offset: &offset).reduce(T.zero) {
            ($0 << 8) | T($1)
        }
    }

    private static func readData(byteCount: Int, from data: Data, offset: inout Int) -> Data {
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: byteCount)
        offset += byteCount
        return data[start ..< end]
    }
}
