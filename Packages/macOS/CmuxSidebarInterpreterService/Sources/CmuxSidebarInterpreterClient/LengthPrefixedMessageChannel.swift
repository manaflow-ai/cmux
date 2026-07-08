#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A framed message channel over a pair of POSIX file descriptors.
///
/// Each message is a 4-byte big-endian length prefix followed by that many
/// bytes of payload (JSON in this package's use). The channel works on raw
/// `Int32` descriptors (which are `Sendable`) rather than `FileHandle` (which
/// is not), so it can be shared between the supervising ``InterpreterClient``
/// actor and its reader thread without ceremony.
///
/// Both ends are blocking syscalls (`read(2)` / `write(2)`): the worker reads a
/// request, the host reads a response, each on its own descriptor. `EINTR` is
/// retried; any other short read/`0` is treated as end-of-stream.
public struct LengthPrefixedMessageChannel: Sendable {
    private let readFD: Int32
    private let writeFD: Int32

    /// Creates a channel that reads from `readFD` and writes to `writeFD`.
    public init(readFD: Int32, writeFD: Int32) {
        self.readFD = readFD
        self.writeFD = writeFD
    }

    /// Frames larger than this are protocol violations: real traffic is JSON
    /// of sidebar source + data context (KBs). The cap stops a corrupted or
    /// hostile peer's length header from forcing a giant allocation.
    public static let maximumFrameLength = 64 * 1024 * 1024

    /// Writes `payload` as one length-prefixed frame. Throws ``ChannelError``
    /// if the descriptor is closed or errors mid-write, or if `payload`
    /// exceeds ``maximumFrameLength``.
    public func sendMessage(_ payload: Data) throws {
        guard payload.count <= Self.maximumFrameLength else {
            throw ChannelError.frameTooLarge
        }
        let count = UInt32(payload.count)
        var header = Data(count: 4)
        header[0] = UInt8((count >> 24) & 0xFF)
        header[1] = UInt8((count >> 16) & 0xFF)
        header[2] = UInt8((count >> 8) & 0xFF)
        header[3] = UInt8(count & 0xFF)
        try writeAll(header)
        if !payload.isEmpty { try writeAll(payload) }
    }

    /// Reads the next length-prefixed frame, or `nil` at end-of-stream (the
    /// peer closed or died) or on a read error. A `nil` is the host's signal
    /// that the worker is gone.
    public func receiveMessage() -> Data? {
        guard let header = readExactly(4) else { return nil }
        let count = (UInt32(header[0]) << 24)
            | (UInt32(header[1]) << 16)
            | (UInt32(header[2]) << 8)
            | UInt32(header[3])
        if count == 0 { return Data() }
        // A peer-controlled length: treat an oversized header like EOF (the
        // peer is broken or hostile) instead of allocating what it asks for.
        guard count <= UInt32(Self.maximumFrameLength) else { return nil }
        return readExactly(Int(count))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(writeFD, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    throw ChannelError.writeFailed
                }
            }
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got: Int = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let base = raw.baseAddress else { return -1 }
                return read(readFD, base + filled, count - filled)
            }
            if got > 0 {
                filled += got
            } else if got == -1 && errno == EINTR {
                continue
            } else {
                return nil // 0 = clean EOF; <0 = error. Either way, peer is gone.
            }
        }
        return Data(buffer)
    }
}

/// A failure writing to a ``LengthPrefixedMessageChannel`` (a closed or broken
/// descriptor, typically because the peer process exited).
public enum ChannelError: Error, Sendable {
    case writeFailed
    /// The outbound payload exceeds ``LengthPrefixedMessageChannel/maximumFrameLength``.
    case frameTooLarge
}
