#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A framed byte channel used by the cmux host and isolated Simulator worker.
///
/// Each payload is prefixed by a four-byte, big-endian unsigned length. The
/// channel uses raw file descriptors so the worker reader thread never needs
/// to move a non-Sendable `FileHandle` across a concurrency boundary.
public struct SimulatorLengthPrefixedMessageChannel: Sendable {
    private let readFD: Int32
    private let writeFD: Int32

    /// The largest accepted frame, preventing a broken child from requesting
    /// an unbounded host allocation.
    public static let maximumFrameLength = 4 * 1024 * 1024

    /// Maximum decoded frames waiting for either process's ordered consumer.
    public static let maximumBufferedFrameCount = 8

    /// Worst-case payload memory admitted by the count-bounded queue.
    public static let maximumBufferedPayloadBytes =
        maximumBufferedFrameCount * maximumFrameLength

    /// Worker exit status used when its bounded inbound queue overflows.
    public static let protocolQueueOverflowExitStatus: Int32 = 75

    /// Creates a channel backed by separate read and write descriptors.
    ///
    /// - Parameters:
    ///   - readFD: Descriptor used to receive frames.
    ///   - writeFD: Descriptor used to send frames.
    ///   - nonblockingWrites: Whether a full peer pipe fails immediately
    ///     instead of blocking its supervising actor.
    public init(readFD: Int32, writeFD: Int32, nonblockingWrites: Bool = false) {
        self.readFD = readFD
        self.writeFD = writeFD
#if canImport(Darwin)
        // A worker crash must surface as EPIPE, never SIGPIPE the cmux host.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
#endif
        if nonblockingWrites {
            let flags = fcntl(writeFD, F_GETFL)
            if flags >= 0 {
                _ = fcntl(writeFD, F_SETFL, flags | O_NONBLOCK)
            }
        }
    }

    /// Writes one complete length-prefixed payload.
    /// - Parameter payload: The bytes to frame and send.
    public func sendMessage(_ payload: Data) throws {
        guard payload.count <= Self.maximumFrameLength else {
            throw SimulatorChannelError.frameTooLarge
        }

        let count = UInt32(payload.count)
        let header = Data([
            UInt8((count >> 24) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8(count & 0xff),
        ])
        try writeAll(header)
        if !payload.isEmpty {
            try writeAll(payload)
        }
    }

    /// Receives one complete payload, or `nil` after EOF, an invalid frame,
    /// or a descriptor error.
    public func receiveMessage() -> Data? {
        guard let header = readExactly(4) else { return nil }
        let count = (UInt32(header[0]) << 24)
            | (UInt32(header[1]) << 16)
            | (UInt32(header[2]) << 8)
            | UInt32(header[3])
        guard count <= UInt32(Self.maximumFrameLength) else { return nil }
        return count == 0 ? Data() : readExactly(Int(count))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(writeFD, baseAddress + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    throw SimulatorChannelError.writeFailed
                }
            }
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let baseAddress = raw.baseAddress else { return -1 }
                return read(readFD, baseAddress + offset, count - offset)
            }
            if received > 0 {
                offset += received
            } else if received == -1, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return Data(bytes)
    }
}

/// An outbound framing failure on a Simulator worker pipe.
public enum SimulatorChannelError: Error, Equatable, Sendable {
    /// The peer closed its input or the descriptor failed while writing.
    case writeFailed
    /// The payload exceeds ``SimulatorLengthPrefixedMessageChannel/maximumFrameLength``.
    case frameTooLarge
}
