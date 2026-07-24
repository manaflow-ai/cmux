public import Foundation

/// Bounded binary framing for Ghostty semantic-scene configuration and frames.
public struct CmxIrohTerminalSceneEnvelopeCodec: Sendable {
    /// Wire failures detected before a record reaches Ghostty.
    public enum DecodeError: Error, Equatable, Sendable {
        case incompleteFrame
        case invalidMagic
        case unsupportedVersion(UInt8)
        case invalidEnvelopeKind(UInt8)
        case invalidSceneKind(UInt8)
        case invalidUTF8
        case invalidReservedBits
        case payloadTooLarge(actual: Int, maximum: Int)
    }

    /// Exact byte count needed to inspect an envelope kind and declared payload.
    public static let headerByteCount = 16

    /// Exact metadata byte count between the common header and opaque payload.
    public static let metadataByteCount = 72

    /// Largest complete record the incremental decoder can retain.
    public static let maximumFrameByteCount = headerByteCount
        + metadataByteCount
        + CmxIrohTerminalSceneFrame.maximumPayloadByteCount

    private enum EnvelopeKind: UInt8 {
        case configuration = 1
        case scene = 2
        case accessibility = 3
    }

    private static let magic = Data("CMXSCN01".utf8)
    private static let version: UInt8 = 1

    public init() {}

    /// Encodes one already validated scene-lane record.
    public func encode(_ envelope: CmxIrohTerminalSceneEnvelope) -> Data {
        var frame = Self.magic
        frame.append(Self.version)
        switch envelope {
        case let .configuration(value):
            frame.append(EnvelopeKind.configuration.rawValue)
            Self.append(UInt16.zero, to: &frame)
            Self.append(UInt32(value.rendererConfig.count), to: &frame)
            Self.append(value.terminalID, to: &frame)
            Self.append(value.terminalEpoch, to: &frame)
            Self.append(value.presentationID, to: &frame)
            Self.append(value.presentationGeneration, to: &frame)
            Self.append(value.rendererConfigRevision, to: &frame)
            Self.append(value.width, to: &frame)
            Self.append(value.height, to: &frame)
            Self.append(value.contentScale.bitPattern, to: &frame)
            frame.append(value.rendererConfig)
        case let .scene(value):
            frame.append(EnvelopeKind.scene.rawValue)
            Self.append(UInt16.zero, to: &frame)
            Self.append(UInt32(value.payload.count), to: &frame)
            Self.append(value.terminalID, to: &frame)
            Self.append(value.terminalEpoch, to: &frame)
            Self.append(value.contentSequence, to: &frame)
            Self.append(value.presentationID, to: &frame)
            Self.append(value.presentationGeneration, to: &frame)
            Self.append(value.presentationSequence, to: &frame)
            frame.append(value.kind.rawValue)
            frame.append(contentsOf: repeatElement(UInt8.zero, count: 7))
            frame.append(value.payload)
        case let .accessibility(value):
            let payload = Data(value.text.utf8)
            frame.append(EnvelopeKind.accessibility.rawValue)
            Self.append(UInt16.zero, to: &frame)
            Self.append(UInt32(payload.count), to: &frame)
            Self.append(value.terminalID, to: &frame)
            Self.append(value.terminalEpoch, to: &frame)
            Self.append(value.contentSequence, to: &frame)
            Self.append(value.presentationID, to: &frame)
            Self.append(value.presentationGeneration, to: &frame)
            Self.append(value.presentationSequence, to: &frame)
            Self.append(value.columns, to: &frame)
            Self.append(value.rows, to: &frame)
            frame.append(payload)
        }
        return frame
    }

    /// Decodes the first complete envelope while preserving following bytes.
    public func decodePrefix(_ data: Data) throws -> CmxIrohDecodedTerminalSceneEnvelope {
        guard data.count >= Self.headerByteCount else {
            throw DecodeError.incompleteFrame
        }
        var reader = Reader(data: data)
        guard try reader.readData(count: Self.magic.count) == Self.magic else {
            throw DecodeError.invalidMagic
        }
        let version = try reader.readUInt8()
        guard version == Self.version else {
            throw DecodeError.unsupportedVersion(version)
        }
        let rawKind = try reader.readUInt8()
        guard let kind = EnvelopeKind(rawValue: rawKind) else {
            throw DecodeError.invalidEnvelopeKind(rawKind)
        }
        guard try reader.readUInt16() == 0 else {
            throw DecodeError.invalidReservedBits
        }
        let payloadByteCount = Int(try reader.readUInt32())
        let maximumPayloadByteCount: Int = switch kind {
        case .configuration:
            CmxIrohTerminalSceneConfiguration.maximumRendererConfigByteCount
        case .scene:
            CmxIrohTerminalSceneFrame.maximumPayloadByteCount
        case .accessibility:
            CmxIrohTerminalSceneAccessibility.maximumTextByteCount
        }
        guard payloadByteCount <= maximumPayloadByteCount else {
            throw DecodeError.payloadTooLarge(
                actual: payloadByteCount,
                maximum: maximumPayloadByteCount
            )
        }
        let consumedByteCount = Self.headerByteCount
            + Self.metadataByteCount
            + payloadByteCount
        guard data.count >= consumedByteCount else {
            throw DecodeError.incompleteFrame
        }

        let envelope: CmxIrohTerminalSceneEnvelope
        switch kind {
        case .configuration:
            envelope = .configuration(try CmxIrohTerminalSceneConfiguration(
                terminalID: reader.readUUID(),
                terminalEpoch: reader.readUInt64(),
                presentationID: reader.readUUID(),
                presentationGeneration: reader.readUInt64(),
                rendererConfigRevision: reader.readUInt64(),
                width: reader.readUInt32(),
                height: reader.readUInt32(),
                contentScale: Double(bitPattern: reader.readUInt64()),
                rendererConfig: reader.readData(count: payloadByteCount)
            ))
        case .scene:
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let contentSequence = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let presentationGeneration = try reader.readUInt64()
            let presentationSequence = try reader.readUInt64()
            let rawSceneKind = try reader.readUInt8()
            guard let sceneKind = CmxIrohTerminalSceneFrame.Kind(rawValue: rawSceneKind) else {
                throw DecodeError.invalidSceneKind(rawSceneKind)
            }
            guard try reader.readData(count: 7).allSatisfy({ $0 == 0 }) else {
                throw DecodeError.invalidReservedBits
            }
            envelope = .scene(try CmxIrohTerminalSceneFrame(
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                contentSequence: contentSequence,
                presentationID: presentationID,
                presentationGeneration: presentationGeneration,
                presentationSequence: presentationSequence,
                kind: sceneKind,
                payload: reader.readData(count: payloadByteCount)
            ))
        case .accessibility:
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let contentSequence = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let presentationGeneration = try reader.readUInt64()
            let presentationSequence = try reader.readUInt64()
            let columns = try reader.readUInt32()
            let rows = try reader.readUInt32()
            let payload = try reader.readData(count: payloadByteCount)
            guard let text = String(data: payload, encoding: .utf8) else {
                throw DecodeError.invalidUTF8
            }
            envelope = .accessibility(try CmxIrohTerminalSceneAccessibility(
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                contentSequence: contentSequence,
                presentationID: presentationID,
                presentationGeneration: presentationGeneration,
                presentationSequence: presentationSequence,
                columns: columns,
                rows: rows,
                text: text
            ))
        }
        return CmxIrohDecodedTerminalSceneEnvelope(
            envelope: envelope,
            consumedByteCount: consumedByteCount
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UUID, to data: inout Data) {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func readData(count: Int) throws -> Data {
            guard count >= 0, offset <= data.count - count else {
                throw DecodeError.incompleteFrame
            }
            defer { offset += count }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: count)
            return Data(data[start ..< end])
        }

        mutating func readUInt8() throws -> UInt8 {
            try readData(count: 1)[0]
        }

        mutating func readUInt16() throws -> UInt16 {
            try readInteger(count: 2)
        }

        mutating func readUInt32() throws -> UInt32 {
            try readInteger(count: 4)
        }

        mutating func readUInt64() throws -> UInt64 {
            try readInteger(count: 8)
        }

        mutating func readUUID() throws -> UUID {
            let bytes = Array(try readData(count: 16))
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }

        private mutating func readInteger<T: FixedWidthInteger>(
            count: Int
        ) throws -> T {
            try readData(count: count).reduce(T.zero) {
                ($0 << 8) | T($1)
            }
        }
    }
}
