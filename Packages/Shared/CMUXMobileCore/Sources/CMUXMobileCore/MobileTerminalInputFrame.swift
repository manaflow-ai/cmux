public import Foundation

/// A terminal input frame with an optional opaque measurement marker and an
/// optional delivery identity.
///
/// Marked frames require the host's `terminal.input.latency.v1` capability.
/// Frames with a ``MobileTerminalInputDelivery`` require
/// ``MobileTerminalInputDelivery/capability``: the host verifies the frame's
/// terminal against the lane it arrived on, applies each sequence exactly
/// once in order, and acknowledges it.
///
/// Wire layout: a 4-byte big-endian header, then the optional 8-byte marker,
/// then the optional 40-byte delivery identity, then UTF-8 text. Header bit 31
/// marks the marker, bit 30 the delivery identity, and the low 30 bits are the
/// byte count of everything after the header.
public struct MobileTerminalInputFrame: Equatable, Sendable {
    public static let capability = "terminal.input.latency.v1"
    public static let maximumInputBytes = 16 * 1_024
    public static let maximumFrameBytes = maximumInputBytes + 4 + markerByteCount
        + MobileTerminalInputDelivery.encodedByteCount
    public let text: String
    public let sequence: UInt64?
    public let delivery: MobileTerminalInputDelivery?

    public enum FrameError: Error { case invalidLength, invalidUTF8 }

    private static let markerFlag: UInt32 = 0x8000_0000
    private static let deliveryFlag: UInt32 = 0x4000_0000
    private static let lengthMask: UInt32 = 0x3fff_ffff
    private static let markerByteCount = 8

    public init(text: String, sequence: UInt64? = nil, delivery: MobileTerminalInputDelivery? = nil) {
        self.text = text
        self.sequence = sequence
        self.delivery = delivery
    }

    public func encoded() throws -> Data {
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumInputBytes else {
            throw FrameError.invalidLength
        }
        var metadata = Data()
        var flags: UInt32 = 0
        if var sequence = sequence?.bigEndian {
            flags |= Self.markerFlag
            withUnsafeBytes(of: &sequence) { metadata.append(contentsOf: $0) }
        }
        if let delivery {
            flags |= Self.deliveryFlag
            metadata.append(delivery.encoded())
        }
        var header = (UInt32(bytes.count + metadata.count) | flags).bigEndian
        var frame = withUnsafeBytes(of: &header) { Data($0) }
        frame.append(metadata)
        frame.append(bytes)
        return frame
    }

    /// Retains partial frames and accepts legacy UTF-8 frames unchanged.
    public static func decode(from buffer: inout Data) throws -> [Self] {
        var frames: [Self] = []
        while buffer.count >= 4 {
            let header = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let marked = header & markerFlag != 0
            let delivered = header & deliveryFlag != 0
            let length = Int(header & lengthMask)
            let metadataBytes = (marked ? markerByteCount : 0)
                + (delivered ? MobileTerminalInputDelivery.encodedByteCount : 0)
            guard length > metadataBytes, length <= maximumInputBytes + metadataBytes else {
                throw FrameError.invalidLength
            }
            guard buffer.count >= length + 4 else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            var offset = 0
            var sequence: UInt64?
            if marked {
                sequence = payload.prefix(markerByteCount).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                offset += markerByteCount
            }
            var delivery: MobileTerminalInputDelivery?
            if delivered {
                let identity = payload.dropFirst(offset).prefix(MobileTerminalInputDelivery.encodedByteCount)
                guard let decoded = MobileTerminalInputDelivery(decoding: Data(identity)) else {
                    throw FrameError.invalidLength
                }
                delivery = decoded
                offset += MobileTerminalInputDelivery.encodedByteCount
            }
            guard let text = String(data: payload.dropFirst(offset), encoding: .utf8) else {
                throw FrameError.invalidUTF8
            }
            frames.append(Self(text: text, sequence: sequence, delivery: delivery))
            buffer.removeFirst(length + 4)
        }
        return frames
    }
}
