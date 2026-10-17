public import Foundation

/// Cuts a command's output into lines and keeps only the newest one.
///
/// Memory stays bounded by ``maxLineBytes`` whatever the command prints: a
/// longer line is cut there and the rest of it is skipped up to its newline.
public struct StatusBarLineReader: Sendable {
    /// Longest line kept, in bytes. Far wider than any window, with room for
    /// the escape sequences and link targets a styled line carries.
    public static let maxLineBytes = 8192

    private var pending = Data()

    /// Creates an empty reader.
    public init() {}

    /// Adds `chunk` and returns the newest non-empty line it completed, or
    /// nil when it completed none.
    public mutating func append(_ chunk: Data) -> String? {
        var newest: Data?
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
            keep(chunk[start..<newline])
            if !pending.isEmpty { newest = pending }
            pending.removeAll(keepingCapacity: true)
            start = chunk.index(after: newline)
        }
        keep(chunk[start...])
        return newest.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns the last line when the output ended without a newline.
    public mutating func finish() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }

    private mutating func keep(_ bytes: Data) {
        pending.append(bytes.prefix(max(Self.maxLineBytes - pending.count, 0)))
    }
}
