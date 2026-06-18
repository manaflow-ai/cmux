internal import Darwin
internal import Foundation

/// Blocking newline-framed reader for one accepted control-socket client,
/// lifted byte-faithfully from the legacy `TerminalController.handleClient`
/// read loop.
///
/// One instance serves one connection on one dedicated client-handler thread;
/// the type is intentionally not thread-safe. The reader never closes the
/// descriptor — connection ownership stays with the handler.
///
/// Framing contract (all legacy behavior, pinned by tests):
/// - Reads up to `bufferSize - 1` bytes per `read(2)` call.
/// - A chunk that is not valid UTF-8 is dropped wholesale (the legacy
///   `String(bytes:encoding:) ?? ""` coalesce).
/// - Lines are split on bare `\n` only. Swift strings treat CRLF as a single
///   grapheme cluster, so `\r\n` does not terminate a line (clients must
///   frame with bare `\n`). Returned lines may be empty or whitespace-only.
/// - `shouldContinueReading` is consulted before each blocking `read(2)` —
///   never between lines already buffered — mirroring the legacy per-read
///   `isRunning` poll.
/// - EOF, a read error, or a `false` poll ends the stream (`nil`); buffered
///   bytes without a trailing newline are discarded, as before.
public final class ControlClientLineReader {
    private let socket: Int32
    private var buffer: [UInt8]
    private var pending = ""

    /// Creates a reader for `socket`.
    /// - Parameters:
    ///   - socket: The connection's descriptor; not closed by the reader.
    ///   - bufferSize: Read buffer size; the legacy loop read at most
    ///     `bufferSize - 1` bytes per call.
    public init(socket: Int32, bufferSize: Int = 4096) {
        self.socket = socket
        self.buffer = [UInt8](repeating: 0, count: bufferSize)
    }

    /// Returns the next newline-terminated line (without the newline), or
    /// `nil` when the connection ended or `shouldContinueReading` returned
    /// `false` before a blocking read.
    /// - Parameter shouldContinueReading: Polled before each `read(2)`;
    ///   typically the listener's `isRunning`.
    public func nextLine(shouldContinueReading: () -> Bool) -> String? {
        while true {
            if let newlineIndex = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newlineIndex])
                pending = String(pending[pending.index(after: newlineIndex)...])
                return line
            }

            guard shouldContinueReading() else { return nil }
            let bytesRead = read(socket, &buffer, buffer.count - 1)
            guard bytesRead > 0 else { return nil }

            let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            pending.append(chunk)
        }
    }
}
