#if canImport(Darwin)
internal import Darwin
#endif
public import Foundation

/// A bounded, length-prefixed control channel over two POSIX descriptors.
///
/// Frame pixels and IOSurface capabilities use the Mach channel. This pipe
/// carries only versioned commands, acknowledgements, and diagnostics.
public struct TerminalRenderMessageChannel: Sendable {
    private let readDescriptor: Int32
    private let writeDescriptor: Int32

    /// The largest accepted control payload.
    public static let maximumFrameLength = 16 * 1024 * 1024

    /// Creates a channel and disables SIGPIPE on its writer.
    public init(
        readDescriptor: Int32,
        writeDescriptor: Int32,
        nonblockingWrites: Bool = false
    ) {
        self.readDescriptor = readDescriptor
        self.writeDescriptor = writeDescriptor
        if writeDescriptor >= 0 {
            _ = fcntl(writeDescriptor, F_SETNOSIGPIPE, 1)
            if nonblockingWrites {
                let flags = fcntl(writeDescriptor, F_GETFL)
                if flags >= 0 {
                    _ = fcntl(writeDescriptor, F_SETFL, flags | O_NONBLOCK)
                }
            }
        }
    }

    /// Writes one complete control payload.
    public func send(_ payload: Data) throws {
        guard payload.count <= Self.maximumFrameLength else {
            throw TerminalRenderChannelError.frameTooLarge
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

    /// Reads one complete control payload, or nil after EOF/protocol failure.
    public func receive() -> Data? {
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
                let written = Darwin.write(
                    writeDescriptor,
                    baseAddress.advanced(by: offset),
                    raw.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    throw TerminalRenderChannelError.writeFailed
                }
            }
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let amount = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let baseAddress = raw.baseAddress else { return -1 }
                return Darwin.read(
                    readDescriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
            }
            if amount > 0 {
                offset += amount
            } else if amount == -1, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return Data(bytes)
    }
}

/// Terminal render control-channel failures.
public enum TerminalRenderChannelError: Error, Equatable, Sendable {
    case frameTooLarge
    case writeFailed
}
