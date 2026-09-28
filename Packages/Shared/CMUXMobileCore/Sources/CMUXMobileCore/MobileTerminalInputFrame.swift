public import Foundation

/// A terminal input frame with an optional opaque measurement marker.
/// Marked frames require the host's `terminal.input.latency.v1` capability.
public struct MobileTerminalInputFrame: Equatable, Sendable {
    public static let capability = "terminal.input.latency.v1"
    public static let maximumInputBytes = 16 * 1_024
    public static let maximumFrameBytes = maximumInputBytes + 12
    public let text: String
    public let sequence: UInt64?

    public enum FrameError: Error { case invalidLength, invalidUTF8 }

    public init(text: String, sequence: UInt64? = nil) {
        self.text = text
        self.sequence = sequence
    }

    public func encoded() throws -> Data {
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumInputBytes else {
            throw FrameError.invalidLength
        }
        let metadataBytes = sequence == nil ? 0 : 8
        var header = (UInt32(bytes.count + metadataBytes) | (sequence == nil ? 0 : 0x8000_0000)).bigEndian
        var frame = withUnsafeBytes(of: &header) { Data($0) }
        if var sequence = sequence?.bigEndian {
            withUnsafeBytes(of: &sequence) { frame.append(contentsOf: $0) }
        }
        frame.append(bytes)
        return frame
    }

    /// Retains partial frames and accepts legacy UTF-8 frames unchanged.
    public static func decode(from buffer: inout Data) throws -> [Self] {
        var frames: [Self] = []
        while buffer.count >= 4 {
            let header = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let marked = header & 0x8000_0000 != 0
            let length = Int(header & 0x7fff_ffff)
            let metadataBytes = marked ? 8 : 0
            guard length > metadataBytes, length <= maximumInputBytes + metadataBytes else {
                throw FrameError.invalidLength
            }
            guard buffer.count >= length + 4 else { break }
            let payload = buffer.dropFirst(4).prefix(length)
            let sequence: UInt64? = marked
                ? payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                : nil
            guard let text = String(data: payload.dropFirst(metadataBytes), encoding: .utf8) else {
                throw FrameError.invalidUTF8
            }
            frames.append(Self(text: text, sequence: sequence))
            buffer.removeFirst(length + 4)
        }
        return frames
    }
}
