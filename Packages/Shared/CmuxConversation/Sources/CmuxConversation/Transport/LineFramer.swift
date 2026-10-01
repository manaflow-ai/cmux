public import Foundation

/// Splits a byte stream into newline-terminated lines, with a cap.
///
/// A line longer than ``maximumLineBytes`` is a protocol violation rather
/// than unbounded memory: ``append(_:)`` throws and the caller resets the
/// connection.
public struct LineFramer: Sendable {
    /// The longest line accepted, in bytes.
    public let maximumLineBytes: Int
    private var buffer = Data()

    /// A line exceeded ``maximumLineBytes``.
    public struct LineTooLong: Error, Hashable, Sendable {}

    /// Creates a framer.
    /// - Parameter maximumLineBytes: The longest line accepted; defaults to
    ///   64 MiB, enough for a large history page.
    public init(maximumLineBytes: Int = 64 << 20) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// Adds bytes and returns every line they complete, without newlines.
    /// Empty lines are skipped.
    /// - Parameter data: Bytes read from the stream.
    /// - Returns: Complete lines.
    /// - Throws: ``LineTooLong`` when a line exceeds the cap.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if buffer.count > maximumLineBytes {
            throw LineTooLong()
        }
        return lines
    }
}
