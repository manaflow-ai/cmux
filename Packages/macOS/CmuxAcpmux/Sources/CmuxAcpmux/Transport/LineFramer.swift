import Foundation

/// Splits a byte stream into newline-delimited frames.
///
/// acpmux writes one JSON-RPC message per line. Socket reads can split a message or
/// carry several, so the framer buffers the partial tail between calls.
///
/// ```swift
/// var framer = LineFramer()
/// let frames = framer.append(Data("{\"a\":1}\n{\"b\"".utf8)) // one frame, tail kept
/// ```
public struct LineFramer: Sendable {
    private var buffer = Data()
    /// The largest partial line kept before the framer reports an overflow.
    public let maximumLineLength: Int

    /// Creates a framer.
    /// - Parameter maximumLineLength: Upper bound for one unterminated line. The default
    ///   (64 MiB) exceeds any attach page acpmux returns while still bounding memory.
    public init(maximumLineLength: Int = 64 * 1024 * 1024) {
        self.maximumLineLength = maximumLineLength
    }

    /// Appends bytes and returns every complete line, without the trailing newline.
    ///
    /// Empty lines and a trailing `\r` are dropped.
    /// - Throws: ``LineFramerError/lineTooLong`` when the partial line exceeds the limit.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var line = buffer[start..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { frames.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        if start != buffer.startIndex {
            buffer = Data(buffer[start...])
        }
        if buffer.count > maximumLineLength {
            buffer = Data()
            throw LineFramerError.lineTooLong
        }
        return frames
    }

    /// Encodes one frame by appending the newline terminator.
    public static func frame(_ payload: Data) -> Data {
        var data = payload
        data.append(0x0A)
        return data
    }
}

/// Errors raised by ``LineFramer``.
public enum LineFramerError: Error, Sendable, Equatable {
    /// A single line exceeded ``LineFramer/maximumLineLength``.
    case lineTooLong
}
