import Foundation

/// Incremental parser for a tmux control-mode (`tmux -CC`) byte stream.
///
/// Feed raw bytes as they arrive from the SSH process; the parser buffers
/// partial lines, strips the `ESC P 1000 p` / `ESC \` DCS framing and the
/// `\r` that the SSH `-tt` pty adds, coalesces `%begin`…`%end` command blocks,
/// and emits structured ``RemoteTmuxControlMessage`` values.
///
/// The protocol is line-oriented: notifications and command-block content are
/// ASCII (tmux octal-escapes control bytes), so they are decoded to `String`. The
/// exception is `%output`, whose payload carries raw pane bytes — including the
/// high bytes of multi-byte UTF-8 characters, which tmux does NOT escape and can
/// split across two notifications. `%output` is therefore parsed from raw bytes
/// (see ``parseOutput(rawLine:)``) so those characters survive for ghostty to
/// reassemble; a String round-trip would replace each split half with U+FFFD.
public struct RemoteTmuxControlStreamParser {
    private let maxBufferedLineBytes: Int
    private let maxCommandBlockBytes: Int
    private var buffer: [UInt8] = []
    private var inBlock = false
    private var blockNumber = 0
    private var blockLines: [String] = []
    private var blockBufferedBytes = 0

    /// Creates a parser with optional caps on buffered line and command-block sizes.
    public init(
        maxBufferedLineBytes: Int = 1_048_576,
        maxCommandBlockBytes: Int = 16_777_216
    ) {
        self.maxBufferedLineBytes = max(1, maxBufferedLineBytes)
        self.maxCommandBlockBytes = max(1, maxCommandBlockBytes)
    }

    /// The DCS sequence tmux emits to enter control mode: `ESC P 1000 p`.
    private static let enterSequence: [UInt8] = [0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]

    /// ASCII bytes of the `%output ` notification prefix (used to detect and parse
    /// `%output` lines from raw bytes, before any String decode).
    private static let outputPrefix: [UInt8] = Array("%output ".utf8)

    /// Feeds a chunk of stream bytes and returns any newly completed messages.
    public mutating func feed(_ data: Data) -> [RemoteTmuxControlMessage] {
        var messages: [RemoteTmuxControlMessage] = []
        for byte in data {
            if byte == 0x0a {
                var lineBytes = buffer
                buffer.removeAll(keepingCapacity: true)
                if lineBytes.last == 0x0d { lineBytes.removeLast() } // strip pty CR
                for message in parse(lineBytes: lineBytes) {
                    messages.append(message)
                    if case .streamError = message { return messages }
                }
            } else {
                buffer.append(byte)
                if buffer.count > maxBufferedLineBytes {
                    messages.append(streamError("line exceeded \(maxBufferedLineBytes) bytes"))
                    return messages
                }
            }
        }
        return messages
    }

    private mutating func parse(lineBytes rawBytes: [UInt8]) -> [RemoteTmuxControlMessage] {
        var bytes = rawBytes
        var prefixMessages: [RemoteTmuxControlMessage] = []

        // Strip a leading enter DCS (it is prepended to the first %begin line).
        if bytes.starts(with: Self.enterSequence) {
            prefixMessages.append(.enter)
            bytes.removeFirst(Self.enterSequence.count)
        }
        // Drop ST (ESC \) DCS-teardown framing — but ONLY on notification lines.
        // Command-block content (e.g. `capture-pane -e` output) is raw terminal
        // bytes that can legitimately contain ESC `\` (an OSC String Terminator),
        // and stripping those would corrupt the painted pane. tmux frames the
        // block, so block content is never DCS-framed.
        if !inBlock {
            bytes = Self.removingST(bytes)
        }
        if bytes.isEmpty { return prefixMessages }

        // `%output` is the only notification whose payload carries raw, possibly
        // multi-byte UTF-8 pane bytes. Parse it straight from the raw bytes so a
        // character that tmux split across two `%output` notifications (it sends
        // pane bytes raw and chunks PTY reads mid-character) survives intact —
        // ghostty's stream parser reassembles split UTF-8 across process_output
        // calls, but routing each half through `String(decoding:as: UTF8.self)`
        // first would replace it with U+FFFD before ghostty ever sees it.
        if !inBlock, let output = Self.parseOutput(rawLine: bytes) {
            return prefixMessages + [output]
        }

        let line = String(decoding: bytes, as: UTF8.self)

        if inBlock {
            // Only a %end/%error whose command number matches this block's
            // %begin terminates it. tmux does NOT escape command output inside a
            // block, so a captured pane line like "%end 1 0 0" must be treated
            // as content, not a terminator (otherwise the block truncates and
            // the command-correlation FIFO desyncs permanently).
            if (line.hasPrefix("%end ") || line.hasPrefix("%error ")),
               Self.field(line, 2).flatMap({ Int($0) }) == blockNumber {
                let isError = line.hasPrefix("%error ")
                let result = RemoteTmuxControlMessage.commandResult(
                    commandNumber: blockNumber, lines: blockLines, isError: isError
                )
                inBlock = false
                blockLines = []
                blockBufferedBytes = 0
                return prefixMessages + [result]
            }
            // Block content is always tmux-formatted text — `capture-pane`/
            // `display-message` responses are printable/escaped, never raw PTY
            // bytes split mid-character — so this String round-trip is lossless.
            // Only `%output` (handled above, from raw bytes) carries raw PTY bytes
            // that a String decode would corrupt.
            if blockBufferedBytes + bytes.count + 1 > maxCommandBlockBytes {
                return prefixMessages + [streamError("command block exceeded \(maxCommandBlockBytes) bytes")]
            }
            blockBufferedBytes += bytes.count + 1
            blockLines.append(line)
            return prefixMessages
        }

        if line.hasPrefix("%begin ") {
            guard let number = Self.field(line, 2).flatMap({ Int($0) }) else {
                // Malformed `%begin` (missing/non-numeric command number): do NOT enter
                // block mode — `blockNumber = 0` would swallow every later line until a
                // matching `%end ... 0` and wedge the mirror until reconnect. Treat the
                // bad line as a normal notification instead.
                return prefixMessages + [parseNotification(line)]
            }
            blockNumber = number
            inBlock = true
            blockLines = []
            blockBufferedBytes = 0
            return prefixMessages
        }

        return prefixMessages + [parseNotification(line)]
    }

    private mutating func streamError(_ reason: String) -> RemoteTmuxControlMessage {
        buffer.removeAll(keepingCapacity: false)
        inBlock = false
        blockNumber = 0
        blockLines = []
        blockBufferedBytes = 0
        return .streamError(reason)
    }

    /// Parses an `%output %<pane> <octal-escaped data…>` line directly from its raw
    /// bytes, preserving the data's multi-byte UTF-8 exactly. Returns `nil` if the
    /// line is not a well-formed `%output` notification, so the caller falls back to
    /// the String-based notification parser.
    ///
    /// Only the prefix and pane id (pure ASCII) are interpreted as text; the data
    /// after the second space is unescaped from raw bytes, so a multi-byte
    /// character split across two `%output` notifications is never replaced with
    /// U+FFFD.
    private static func parseOutput(rawLine bytes: [UInt8]) -> RemoteTmuxControlMessage? {
        guard bytes.starts(with: outputPrefix) else { return nil }
        var i = outputPrefix.count
        guard i < bytes.count, bytes[i] == UInt8(ascii: "%") else { return nil }
        i += 1
        let digitsStart = i
        while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
            i += 1
        }
        guard i > digitsStart, i < bytes.count, bytes[i] == UInt8(ascii: " "),
              let paneId = Int(String(decoding: bytes[digitsStart..<i], as: UTF8.self))
        else { return nil }
        return .output(paneId: paneId, data: unescapeOutput(Array(bytes[(i + 1)...])))
    }

    private func parseNotification(_ line: String) -> RemoteTmuxControlMessage {
        if line == "%exit" || line.hasPrefix("%exit ") {
            let reason = line == "%exit" ? nil : String(line.dropFirst("%exit ".count))
            return .exit(reason: reason)
        }
        // NOTE: `%output` is parsed earlier from raw bytes in `parse(lineBytes:)`
        // (see `parseOutput(rawLine:)`), never here — routing its payload through
        // this String would corrupt multi-byte UTF-8 split across notifications. A
        // malformed `%output` that `parseOutput` rejects falls through to the
        // `%`-prefix catch-all below as `.ignoredNotification`.
        if line.hasPrefix("%session-changed ") {
            guard let id = Self.fieldId(line, 1, sigil: "$") else { return .unparsed(line) }
            // Session names may contain spaces; join the remaining fields.
            return .sessionChanged(sessionId: id, name: Self.fieldsFrom(line, 2))
        }
        if line == "%sessions-changed" { return .sessionsChanged }
        if line.hasPrefix("%window-add ") {
            guard let id = Self.fieldId(line, 1, sigil: "@") else { return .unparsed(line) }
            return .windowAdd(windowId: id)
        }
        if line.hasPrefix("%window-close ") || line.hasPrefix("%unlinked-window-close ") {
            guard let id = Self.fieldId(line, 1, sigil: "@") else { return .unparsed(line) }
            return .windowClose(windowId: id)
        }
        if line.hasPrefix("%window-renamed ") {
            guard let id = Self.fieldId(line, 1, sigil: "@") else { return .unparsed(line) }
            let name = Self.fieldsFrom(line, 2)
            return .windowRenamed(windowId: id, name: name)
        }
        if line.hasPrefix("%layout-change ") {
            guard let id = Self.fieldId(line, 1, sigil: "@"),
                  let layout = Self.field(line, 2) else { return .unparsed(line) }
            return .layoutChange(windowId: id, layout: layout)
        }
        if line.hasPrefix("%window-pane-changed ") {
            guard let id = Self.fieldId(line, 1, sigil: "@"),
                  let pane = Self.fieldId(line, 2, sigil: "%") else { return .unparsed(line) }
            return .windowPaneChanged(windowId: id, paneId: pane)
        }
        if line.hasPrefix("%session-window-changed ") {
            guard let sid = Self.fieldId(line, 1, sigil: "$"),
                  let wid = Self.fieldId(line, 2, sigil: "@") else { return .unparsed(line) }
            return .sessionWindowChanged(sessionId: sid, windowId: wid)
        }
        if line.hasPrefix("%subscription-changed ") {
            guard let name = Self.field(line, 1) else { return .ignoredNotification(line) }
            // The value is everything after the first " : " separator. The middle
            // fields (session/window/pane/flags) vary by tmux version, so key off
            // the subscription name instead of a fixed field index.
            let value = line.range(of: " : ").map { String(line[$0.upperBound...]) } ?? ""
            return .subscriptionChanged(name: name, value: value)
        }
        if line.hasPrefix("%") { return .ignoredNotification(line) }
        return .unparsed(line)
    }

    // MARK: - Helpers

    /// Returns the whitespace-separated field at `index` (0-based).
    private static func field(_ line: String, _ index: Int) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard index < parts.count else { return nil }
        return String(parts[index])
    }

    /// All fields from `index` onward, rejoined with spaces (for names that may contain spaces).
    private static func fieldsFrom(_ line: String, _ index: Int) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard index < parts.count else { return "" }
        return parts[index...].joined(separator: " ")
    }

    /// Parses the field at `index` as a sigil-prefixed tmux id (`$`/`@`/`%`).
    private static func fieldId(_ line: String, _ index: Int, sigil: Character) -> Int? {
        guard let token = field(line, index) else { return nil }
        return id(Substring(token), sigil: sigil)
    }

    /// Parses a sigil-prefixed tmux id token, e.g. `@4` → 4, `%8` → 8, `$2` → 2.
    public static func id(_ token: Substring, sigil: Character) -> Int? {
        guard token.first == sigil else { return nil }
        return Int(token.dropFirst())
    }

    /// Removes any `ESC \` (ST) sequences from a line's bytes.
    private static func removingST(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(0x1b) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1b, i + 1 < bytes.count, bytes[i + 1] == 0x5c {
                i += 2
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return out
    }

    /// Octal-unescapes raw `%output` data bytes (`\ooo` → byte). Any byte that is
    /// not part of a `\ooo` escape — including the raw high bytes of a multi-byte
    /// UTF-8 character — passes through unchanged, so split or whole UTF-8 text
    /// survives intact for ghostty to decode.
    static func unescapeOutput(_ bytes: [UInt8]) -> Data {
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = 0
        let isOctal: (UInt8) -> Bool = { $0 >= 0x30 && $0 <= 0x37 }
        while i < bytes.count {
            if bytes[i] == 0x5c, // backslash
               i + 3 < bytes.count,
               isOctal(bytes[i + 1]), isOctal(bytes[i + 2]), isOctal(bytes[i + 3]) {
                // Compute in Int to avoid a UInt8 overflow trap on malformed
                // escapes like \777; emit literally if out of byte range.
                let value = Int(bytes[i + 1] - 0x30) * 64
                    + Int(bytes[i + 2] - 0x30) * 8
                    + Int(bytes[i + 3] - 0x30)
                if value <= 0xFF {
                    out.append(UInt8(value))
                    i += 4
                } else {
                    out.append(bytes[i])
                    i += 1
                }
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}
