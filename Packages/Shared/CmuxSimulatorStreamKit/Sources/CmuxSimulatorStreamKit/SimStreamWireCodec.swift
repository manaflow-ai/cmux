import Foundation

public enum SimStreamWireError: Error, Equatable {
    case truncated
    case messageTooLarge(byteCount: Int)
    case unknownMessageType(UInt8)
    case unknownEnumValue(field: String, value: UInt8)
    case invalidUTF8
    case trailingBytes(count: Int)
}

/// Binary codec for `SimStreamMessage`.
///
/// Layout: every message body is `u8 type` followed by type-specific fields.
/// Integers are big-endian. Variable-length data uses a `u32` byte-count
/// prefix. On the wire each body is additionally framed by a `u32` length
/// prefix (see `encodeFramed` / `SimStreamFrameAccumulator`).
public enum SimStreamWireCodec {
    private enum MessageType: UInt8 {
        case start = 0x01
        case config = 0x02
        case frame = 0x03
        case ack = 0x04
        case input = 0x05
        case keyframeRequest = 0x06
        case stop = 0x07
        case state = 0x08
    }

    private enum InputEventKind: UInt8 {
        case touch = 0x01
        case text = 0x02
        case key = 0x03
        case button = 0x04
    }

    // MARK: - Encode

    public static func encode(_ message: SimStreamMessage) -> Data {
        var writer = SimStreamByteWriter()
        switch message {
        case .start(let start):
            writer.writeUInt8(MessageType.start.rawValue)
            writer.writeUInt8(start.version)
            writer.writeUInt64(start.epoch)
            writer.writeUInt16(start.maximumLongSidePixels)
            writer.writeUInt8(UInt8(clamping: start.codecPreferences.count))
            for codec in start.codecPreferences.prefix(Int(UInt8.max)) {
                writer.writeUInt8(codec.rawValue)
            }
        case .config(let config):
            writer.writeUInt8(MessageType.config.rawValue)
            writer.writeUInt8(config.codec.rawValue)
            writer.writeUInt32(config.pixelWidth)
            writer.writeUInt32(config.pixelHeight)
            writer.writeFloat(config.displayScale)
            writer.writeUInt8(config.orientation.rawValue)
            writer.writeUInt8(config.nalUnitHeaderLength)
            writer.writeUInt8(UInt8(clamping: config.parameterSets.count))
            for parameterSet in config.parameterSets.prefix(Int(UInt8.max)) {
                writer.writeLengthPrefixedData(parameterSet)
            }
        case .frame(let frame):
            writer.writeUInt8(MessageType.frame.rawValue)
            writer.writeUInt64(frame.sequence)
            writer.writeUInt8(frame.flags.rawValue)
            writer.writeUInt64(frame.presentationMicroseconds)
            writer.writeLengthPrefixedData(frame.payload)
        case .ack(let ack):
            writer.writeUInt8(MessageType.ack.rawValue)
            writer.writeUInt64(ack.sequence)
            writer.writeUInt64(ack.receiptMicroseconds)
        case .input(let batch):
            writer.writeUInt8(MessageType.input.rawValue)
            writer.writeUInt64(batch.sequence)
            writer.writeUInt16(UInt16(clamping: batch.events.count))
            for event in batch.events.prefix(Int(UInt16.max)) {
                encode(event, into: &writer)
            }
        case .keyframeRequest:
            writer.writeUInt8(MessageType.keyframeRequest.rawValue)
        case .stop:
            writer.writeUInt8(MessageType.stop.rawValue)
        case .state(let state):
            writer.writeUInt8(MessageType.state.rawValue)
            writer.writeUInt8(state.status.rawValue)
            writer.writeLengthPrefixedData(Data(state.detail.utf8))
        }
        return writer.data
    }

    private static func encode(
        _ event: SimStreamInputEvent, into writer: inout SimStreamByteWriter
    ) {
        switch event {
        case .touch(let phase, let pointerID, let x, let y, let timestamp):
            writer.writeUInt8(InputEventKind.touch.rawValue)
            writer.writeUInt8(phase.rawValue)
            writer.writeUInt8(pointerID)
            writer.writeFloat(x)
            writer.writeFloat(y)
            writer.writeUInt64(timestamp)
        case .text(let text):
            writer.writeUInt8(InputEventKind.text.rawValue)
            writer.writeLengthPrefixedData(Data(text.utf8))
        case .key(let usage, let isDown):
            writer.writeUInt8(InputEventKind.key.rawValue)
            writer.writeUInt16(usage)
            writer.writeUInt8(isDown ? 1 : 0)
        case .button(let button):
            writer.writeUInt8(InputEventKind.button.rawValue)
            writer.writeUInt8(button.rawValue)
        }
    }

    /// Encodes a message with the `u32` wire length prefix.
    public static func encodeFramed(_ message: SimStreamMessage) -> Data {
        let body = encode(message)
        var writer = SimStreamByteWriter()
        writer.writeUInt32(UInt32(body.count))
        writer.data.append(body)
        return writer.data
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> SimStreamMessage {
        var reader = SimStreamByteReader(data: data)
        let message = try decodeBody(&reader)
        if reader.remainingByteCount > 0 {
            throw SimStreamWireError.trailingBytes(count: reader.remainingByteCount)
        }
        return message
    }

    private static func decodeBody(
        _ reader: inout SimStreamByteReader
    ) throws -> SimStreamMessage {
        let rawType = try reader.readUInt8()
        guard let type = MessageType(rawValue: rawType) else {
            throw SimStreamWireError.unknownMessageType(rawType)
        }
        switch type {
        case .start:
            let version = try reader.readUInt8()
            let epoch = try reader.readUInt64()
            let maxLongSide = try reader.readUInt16()
            let codecCount = try reader.readUInt8()
            var codecs: [SimStreamVideoCodec] = []
            codecs.reserveCapacity(Int(codecCount))
            for _ in 0..<codecCount {
                let raw = try reader.readUInt8()
                guard let codec = SimStreamVideoCodec(rawValue: raw) else {
                    // Unknown codecs from a newer viewer are skipped, not
                    // fatal: the host picks from the ones it understands.
                    continue
                }
                codecs.append(codec)
            }
            return .start(
                SimStreamStartRequest(
                    version: version,
                    epoch: epoch,
                    maximumLongSidePixels: maxLongSide,
                    codecPreferences: codecs
                )
            )
        case .config:
            let rawCodec = try reader.readUInt8()
            guard let codec = SimStreamVideoCodec(rawValue: rawCodec) else {
                throw SimStreamWireError.unknownEnumValue(field: "codec", value: rawCodec)
            }
            let pixelWidth = try reader.readUInt32()
            let pixelHeight = try reader.readUInt32()
            let displayScale = try reader.readFloat()
            let rawOrientation = try reader.readUInt8()
            guard let orientation = SimStreamOrientation(rawValue: rawOrientation) else {
                throw SimStreamWireError.unknownEnumValue(
                    field: "orientation", value: rawOrientation)
            }
            let nalUnitHeaderLength = try reader.readUInt8()
            let parameterSetCount = try reader.readUInt8()
            var parameterSets: [Data] = []
            parameterSets.reserveCapacity(Int(parameterSetCount))
            for _ in 0..<parameterSetCount {
                parameterSets.append(try reader.readLengthPrefixedData())
            }
            return .config(
                SimStreamConfig(
                    codec: codec,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    displayScale: displayScale,
                    orientation: orientation,
                    parameterSets: parameterSets,
                    nalUnitHeaderLength: nalUnitHeaderLength
                )
            )
        case .frame:
            let sequence = try reader.readUInt64()
            let flags = SimStreamFrame.Flags(rawValue: try reader.readUInt8())
            let pts = try reader.readUInt64()
            let payload = try reader.readLengthPrefixedData()
            return .frame(
                SimStreamFrame(
                    sequence: sequence,
                    flags: flags,
                    presentationMicroseconds: pts,
                    payload: payload
                )
            )
        case .ack:
            let sequence = try reader.readUInt64()
            let receipt = try reader.readUInt64()
            return .ack(SimStreamAck(sequence: sequence, receiptMicroseconds: receipt))
        case .input:
            let sequence = try reader.readUInt64()
            let eventCount = try reader.readUInt16()
            var events: [SimStreamInputEvent] = []
            events.reserveCapacity(Int(eventCount))
            for _ in 0..<eventCount {
                events.append(try decodeInputEvent(&reader))
            }
            return .input(SimStreamInputBatch(sequence: sequence, events: events))
        case .keyframeRequest:
            return .keyframeRequest
        case .stop:
            return .stop
        case .state:
            let rawStatus = try reader.readUInt8()
            guard let status = SimStreamHostStatus(rawValue: rawStatus) else {
                throw SimStreamWireError.unknownEnumValue(field: "status", value: rawStatus)
            }
            let detailData = try reader.readLengthPrefixedData()
            guard let detail = String(data: detailData, encoding: .utf8) else {
                throw SimStreamWireError.invalidUTF8
            }
            return .state(SimStreamStateUpdate(status: status, detail: detail))
        }
    }

    private static func decodeInputEvent(
        _ reader: inout SimStreamByteReader
    ) throws -> SimStreamInputEvent {
        let rawKind = try reader.readUInt8()
        guard let kind = InputEventKind(rawValue: rawKind) else {
            throw SimStreamWireError.unknownEnumValue(field: "input_kind", value: rawKind)
        }
        switch kind {
        case .touch:
            let rawPhase = try reader.readUInt8()
            guard let phase = SimStreamTouchPhase(rawValue: rawPhase) else {
                throw SimStreamWireError.unknownEnumValue(field: "touch_phase", value: rawPhase)
            }
            let pointerID = try reader.readUInt8()
            let x = try reader.readFloat()
            let y = try reader.readFloat()
            let timestamp = try reader.readUInt64()
            return .touch(
                phase: phase, pointerID: pointerID, x: x, y: y,
                timestampMicroseconds: timestamp)
        case .text:
            let textData = try reader.readLengthPrefixedData()
            guard let text = String(data: textData, encoding: .utf8) else {
                throw SimStreamWireError.invalidUTF8
            }
            return .text(text)
        case .key:
            let usage = try reader.readUInt16()
            let isDown = try reader.readUInt8() != 0
            return .key(usage: usage, isDown: isDown)
        case .button:
            let rawButton = try reader.readUInt8()
            guard let button = SimStreamHardwareButton(rawValue: rawButton) else {
                throw SimStreamWireError.unknownEnumValue(field: "button", value: rawButton)
            }
            return .button(button)
        }
    }
}

// MARK: - Byte helpers

public struct SimStreamByteWriter: Sendable {
    public var data = Data()

    public init() {}

    public mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func writeUInt16(_ value: UInt16) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeUInt64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeFloat(_ value: Float) {
        writeUInt32(value.bitPattern)
    }

    public mutating func writeLengthPrefixedData(_ payload: Data) {
        writeUInt32(UInt32(payload.count))
        data.append(payload)
    }
}

public struct SimStreamByteReader: Sendable {
    private let data: Data
    private var offset: Int

    public init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remainingByteCount: Int { data.endIndex - offset }

    public mutating func readUInt8() throws -> UInt8 {
        guard remainingByteCount >= 1 else { throw SimStreamWireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func readUInt16() throws -> UInt16 {
        try UInt16(bigEndian: readFixedWidth())
    }

    public mutating func readUInt32() throws -> UInt32 {
        try UInt32(bigEndian: readFixedWidth())
    }

    public mutating func readUInt64() throws -> UInt64 {
        try UInt64(bigEndian: readFixedWidth())
    }

    public mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    public mutating func readLengthPrefixedData() throws -> Data {
        let count = Int(try readUInt32())
        guard count <= SimStreamProtocol.maximumMessageByteCount else {
            throw SimStreamWireError.messageTooLarge(byteCount: count)
        }
        guard remainingByteCount >= count else { throw SimStreamWireError.truncated }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    private mutating func readFixedWidth<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard remainingByteCount >= size else { throw SimStreamWireError.truncated }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(to: destination, from: offset..<(offset + size))
        }
        offset += size
        return value
    }
}

/// Incremental defragmenter for the `u32`-length-framed message stream.
/// Feed it raw bytes from the transport; it yields complete message bodies.
public struct SimStreamFrameAccumulator: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next complete message body, or nil when more bytes are
    /// needed. Throws when a frame declares an impossible length, which is
    /// unrecoverable for the stream (the caller must close the lane).
    public mutating func nextMessageBody() throws -> Data? {
        let headerSize = 4
        guard buffer.count >= headerSize else { return nil }
        let length = buffer.prefix(headerSize).reduce(into: UInt32(0)) { partial, byte in
            partial = partial << 8 | UInt32(byte)
        }
        guard length <= UInt32(SimStreamProtocol.maximumMessageByteCount) else {
            throw SimStreamWireError.messageTooLarge(byteCount: Int(length))
        }
        let total = headerSize + Int(length)
        guard buffer.count >= total else { return nil }
        let body = buffer.subdata(in: headerSize..<total)
        buffer.removeSubrange(0..<total)
        return body
    }
}
