import Foundation

/// Incremental parser for a tmux control-mode (`tmux -CC`) byte stream.
///
/// Feed raw bytes as they arrive from the SSH process; the parser buffers
/// partial lines, strips the `ESC P 1000 p` / `ESC \` DCS framing and the
/// `\r` that the SSH `-tt` pty adds, coalesces `%begin`…`%end` command blocks,
/// and emits structured ``RemoteTmuxControlMessage`` values.
///
/// The protocol is line-oriented printable ASCII (tmux octal-escapes every
/// non-printable byte in `%output`), so line-based parsing is lossless.
struct RemoteTmuxControlStreamParser {
    private var buffer: [UInt8] = []
    private var inBlock = false
    private var blockNumber = 0
    private var blockLines: [String] = []

    /// The DCS sequence tmux emits to enter control mode: `ESC P 1000 p`.
    private static let enterSequence: [UInt8] = [0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]

    /// Feeds a chunk of stream bytes and returns any newly completed messages.
    mutating func feed(_ data: Data) -> [RemoteTmuxControlMessage] {
        var messages: [RemoteTmuxControlMessage] = []
        buffer.append(contentsOf: data)
        while let newlineIndex = buffer.firstIndex(of: 0x0a) {
            var lineBytes = Array(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if lineBytes.last == 0x0d { lineBytes.removeLast() } // strip pty CR
            for message in parse(lineBytes: lineBytes) { messages.append(message) }
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
                return prefixMessages + [result]
            }
            blockLines.append(line)
            return prefixMessages
        }

        if line.hasPrefix("%begin ") {
            blockNumber = Self.field(line, 2).flatMap { Int($0) } ?? 0
            inBlock = true
            blockLines = []
            return prefixMessages
        }

        return prefixMessages + [parseNotification(line)]
    }

    private func parseNotification(_ line: String) -> RemoteTmuxControlMessage {
        if line == "%exit" || line.hasPrefix("%exit ") {
            let reason = line == "%exit" ? nil : String(line.dropFirst("%exit ".count))
            return .exit(reason: reason)
        }
        if line.hasPrefix("%output ") {
            // %output %<pane> <octal-escaped data...>
            let rest = line.dropFirst("%output ".count)
            guard let space = rest.firstIndex(of: " ") else { return .unparsed(line) }
            let paneToken = rest[..<space]
            guard let paneId = Self.id(paneToken, sigil: "%") else { return .unparsed(line) }
            let dataPart = rest[rest.index(after: space)...]
            return .output(paneId: paneId, data: Self.unescapeOutput(dataPart))
        }
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
    static func id(_ token: Substring, sigil: Character) -> Int? {
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

    /// Octal-unescapes a `%output` data field (`\ooo` → byte) into raw bytes.
    static func unescapeOutput(_ field: Substring) -> Data {
        let bytes = Array(field.utf8)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = 0
        func isOctal(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }
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
