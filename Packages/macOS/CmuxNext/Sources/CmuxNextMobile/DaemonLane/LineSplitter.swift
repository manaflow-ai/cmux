public import Foundation

/// Splits a byte stream into newline-terminated lines with a length cap.
///
/// A line longer than `maximumLineBytes` is a protocol violation: the caller
/// closes the lane rather than buffering without bound.
public struct LineSplitter: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case lineTooLong(limit: Int)
    }

    public let maximumLineBytes: Int
    private var buffer = Data()

    public init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// Bytes held for an unfinished line.
    public var pendingByteCount: Int { buffer.count }

    /// Appends `chunk` and returns every completed line without its `\n`
    /// (a trailing `\r` is kept; v12 never sends one).
    public mutating func append(_ chunk: Data) throws(Failure) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if line.count > maximumLineBytes { throw .lineTooLong(limit: maximumLineBytes) }
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        if buffer.count > maximumLineBytes { throw .lineTooLong(limit: maximumLineBytes) }
        return lines
    }
}
