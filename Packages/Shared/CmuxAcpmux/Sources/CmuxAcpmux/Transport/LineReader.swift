import CmuxConversation
import Foundation

/// Reads newline-delimited lines from a ``ConversationByteStream``, keeping
/// bytes that follow a line for the next call.
struct LineReader {
    private var framer = LineFramer(maximumLineBytes: 4 << 20)
    private var lines: [Data] = []

    /// The next line, or `nil` at end of stream.
    mutating func next(from stream: any ConversationByteStream) async throws -> Data? {
        while lines.isEmpty {
            guard let chunk = try await stream.read(maximumBytes: 64 * 1024) else { return nil }
            lines.append(contentsOf: try framer.append(chunk))
        }
        return lines.removeFirst()
    }
}
