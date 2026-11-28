import Foundation

/// One message from a tmux control-mode stream (`tmux -C`), ported from the
/// Mac's `RemoteTmuxControlStreamParser` (`Sources/RemoteTmuxControlStreamParser.swift`)
/// with the fields the phone needs: command replies keep tmux's `flags`
/// (only blocks with flag 1 answer this client's commands) and their raw
/// line bytes (capture-pane rows carry escape sequences and UTF-8).
enum MobileSSHTmuxControlMessage: Equatable, Sendable {
    /// `%output %<pane> <data>`, with `data` octal-unescaped to raw PTY bytes.
    case output(pane: Int, data: Data)
    /// One `%begin`...`%end`/`%error` block.
    case reply(number: Int, flags: Int, lines: [Data], isError: Bool)
    case exit(reason: String?)
    case sessionChanged(session: Int, name: String)
    case sessionsChanged
    case windowAdd(window: Int)
    /// `%window-close`. `%unlinked-window-*` belong to other sessions and are ignored.
    case windowClose(window: Int)
    case windowRenamed(window: Int, name: String)
    /// `%layout-change @<window> <layout> <visible-layout> <flags>`.
    case layoutChange(window: Int, layout: String, visibleLayout: String?)
    case sessionWindowChanged(session: Int, window: Int)
    case windowPaneChanged(window: Int, pane: Int)
    /// `%pane-mode-changed %<pane>` (copy mode entered or left).
    case paneModeChanged(pane: Int)
    /// A notification the phone does not act on (`%pause`, `%client-*`, ...).
    case other(String)
}

/// Incremental line parser for a `tmux -C` byte stream.
///
/// Notifications are ASCII; `%output` payloads are parsed from raw bytes so
/// a multi-byte UTF-8 character tmux split across two notifications survives
/// for Ghostty to reassemble (a String round-trip would turn each half into
/// U+FFFD). Block content is only terminated by a `%end`/`%error` whose
/// command number matches the `%begin`, because tmux does not escape
/// command output (a captured row may itself read `%end 1 2 1`).
struct MobileSSHTmuxControlParser {
    private var buffer: [UInt8] = []
    private var block: (number: Int, flags: Int, lines: [Data])?
    private let maxLineBytes: Int

    init(maxLineBytes: Int = 4 * 1_024 * 1_024) {
        self.maxLineBytes = maxLineBytes
    }

    private static let outputPrefix = Array("%output ".utf8)

    mutating func feed(_ data: Data) -> [MobileSSHTmuxControlMessage] {
        var messages: [MobileSSHTmuxControlMessage] = []
        for byte in data {
            if byte == 0x0A {
                var line = buffer
                buffer.removeAll(keepingCapacity: true)
                if line.last == 0x0D { line.removeLast() }
                if let message = parse(line) { messages.append(message) }
            } else if buffer.count < maxLineBytes {
                buffer.append(byte)
            }
        }
        return messages
    }

    private mutating func parse(_ bytes: [UInt8]) -> MobileSSHTmuxControlMessage? {
        if var open = block {
            let line = String(decoding: bytes, as: UTF8.self)
            if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                let fields = line.split(separator: " ")
                if fields.count >= 3, Int(fields[2]) == open.number {
                    block = nil
                    return .reply(number: open.number, flags: open.flags, lines: open.lines, isError: line.hasPrefix("%error "))
                }
            }
            open.lines.append(Data(bytes))
            block = open
            return nil
        }
        if bytes.isEmpty { return nil }
        if let output = Self.parseOutput(bytes) { return output }
        let line = String(decoding: bytes, as: UTF8.self)
        let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch fields[0] {
        case "%begin":
            guard fields.count >= 3, let number = Int(fields[2]) else { return .other(line) }
            block = (number, fields.count >= 4 ? Int(fields[3]) ?? 0 : 0, [])
            return nil
        case "%exit":
            return .exit(reason: fields.count > 1 ? fields[1...].joined(separator: " ") : nil)
        case "%session-changed":
            guard fields.count >= 3, let id = Self.id(fields[1], "$") else { return .other(line) }
            return .sessionChanged(session: id, name: fields[2...].joined(separator: " "))
        case "%sessions-changed":
            return .sessionsChanged
        case "%window-add":
            guard fields.count >= 2, let id = Self.id(fields[1], "@") else { return .other(line) }
            return .windowAdd(window: id)
        case "%window-close":
            guard fields.count >= 2, let id = Self.id(fields[1], "@") else { return .other(line) }
            return .windowClose(window: id)
        case "%window-renamed":
            guard fields.count >= 3, let id = Self.id(fields[1], "@") else { return .other(line) }
            return .windowRenamed(window: id, name: fields[2...].joined(separator: " "))
        case "%layout-change":
            guard fields.count >= 3, let id = Self.id(fields[1], "@") else { return .other(line) }
            return .layoutChange(window: id, layout: fields[2], visibleLayout: fields.count >= 4 ? fields[3] : nil)
        case "%session-window-changed":
            guard fields.count >= 3, let session = Self.id(fields[1], "$"), let window = Self.id(fields[2], "@") else { return .other(line) }
            return .sessionWindowChanged(session: session, window: window)
        case "%window-pane-changed":
            guard fields.count >= 3, let window = Self.id(fields[1], "@"), let pane = Self.id(fields[2], "%") else { return .other(line) }
            return .windowPaneChanged(window: window, pane: pane)
        case "%pane-mode-changed":
            guard fields.count >= 2, let pane = Self.id(fields[1], "%") else { return .other(line) }
            return .paneModeChanged(pane: pane)
        default:
            return .other(line)
        }
    }

    static func id(_ token: String, _ sigil: Character) -> Int? {
        guard token.first == sigil else { return nil }
        return Int(token.dropFirst())
    }

    private static func parseOutput(_ bytes: [UInt8]) -> MobileSSHTmuxControlMessage? {
        guard bytes.starts(with: outputPrefix) else { return nil }
        var index = outputPrefix.count
        guard index < bytes.count, bytes[index] == UInt8(ascii: "%") else { return nil }
        index += 1
        let digits = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        guard index > digits, index < bytes.count, bytes[index] == UInt8(ascii: " "),
              let pane = Int(String(decoding: bytes[digits..<index], as: UTF8.self)) else { return nil }
        return .output(pane: pane, data: unescape(bytes[(index + 1)...]))
    }

    /// `\ooo` to one byte; every other byte (including raw UTF-8) passes through.
    static func unescape<C: Collection>(_ input: C) -> Data where C.Element == UInt8 {
        let bytes = Array(input)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var index = 0
        let isOctal: (UInt8) -> Bool = { (0x30...0x37).contains($0) }
        while index < bytes.count {
            if bytes[index] == 0x5C, index + 3 < bytes.count,
               isOctal(bytes[index + 1]), isOctal(bytes[index + 2]), isOctal(bytes[index + 3]) {
                let value = Int(bytes[index + 1] - 0x30) * 64 + Int(bytes[index + 2] - 0x30) * 8 + Int(bytes[index + 3] - 0x30)
                if value <= 0xFF {
                    out.append(UInt8(value))
                    index += 4
                    continue
                }
            }
            out.append(bytes[index])
            index += 1
        }
        return out
    }
}

/// Pane geometry from a tmux layout string (`csum,WxH,x,y{...}` / `[...]`).
/// Leaves are `WxH,x,y,<pane>`; containers are followed by `{` or `[`.
struct MobileSSHTmuxLayout {
    struct Leaf: Equatable, Sendable {
        var pane: Int
        var columns: Int
        var rows: Int
        var x: Int
        var y: Int
    }

    /// The panes, in layout order.
    let leaves: [Leaf]

    init(_ layout: String) {
        // Skip the 4-hex checksum and its comma.
        let parts = layout.split(separator: ",", maxSplits: 1)
        let chars = Array((parts.count == 2 ? parts[1] : Substring(layout)).utf8)
        var leaves: [Leaf] = []
        var index = 0
        func number() -> Int? {
            let start = index
            while index < chars.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(chars[index]) { index += 1 }
            return index > start ? Int(String(decoding: chars[start..<index], as: UTF8.self)) : nil
        }
        func expect(_ byte: UInt8) -> Bool {
            guard index < chars.count, chars[index] == byte else { return false }
            index += 1
            return true
        }
        while index < chars.count {
            let start = index
            if let width = number(), expect(UInt8(ascii: "x")), let height = number(),
               expect(UInt8(ascii: ",")), let x = number(), expect(UInt8(ascii: ",")), let y = number() {
                if expect(UInt8(ascii: ",")), let pane = number() {
                    leaves.append(Leaf(pane: pane, columns: width, rows: height, x: x, y: y))
                }
                continue
            }
            index = max(index, start + 1)
        }
        self.leaves = leaves
    }
}

/// Removes screen-style title sequences (`ESC k <title> ST`) from one pane's
/// `%output` stream.
///
/// Shells that believe they run under screen or tmux (zsh with `TERM=screen*`
/// or `tmux*`, and prompt frameworks that set the window name) emit
/// `ESC k <title> ESC \`. tmux consumes it as the window name, but control
/// mode forwards the pane's raw bytes, and Ghostty does not know the
/// sequence: it drops `ESC k` and prints the title as text. tmux ends the
/// string on ST (`ESC \`) or BEL, like its other string sequences.
///
/// State survives across chunks, so a sequence split between two `%output`
/// notifications is still removed whole. An `ESC` at the end of a chunk is
/// held until the next byte decides whether it starts a title.
struct MobileSSHTmuxTitleSequenceFilter {
    /// Longest title kept; the rest of a longer one is still swallowed.
    static let maxTitleBytes = 1_024

    private enum State {
        case ground
        /// Saw `ESC` outside a title.
        case escape
        /// Inside `ESC k`, collecting the title.
        case title
        /// Saw `ESC` inside a title (`ESC \` ends it).
        case titleEscape
    }

    private var state = State.ground
    private var title: [UInt8] = []

    /// Filters one chunk. Returns the bytes to render and the titles that
    /// completed in this chunk, in order.
    mutating func filter(_ data: Data) -> (output: Data, titles: [String]) {
        var output = Data()
        output.reserveCapacity(data.count)
        var titles: [String] = []
        for byte in data {
            process(byte, output: &output, titles: &titles)
        }
        return (output, titles)
    }

    private mutating func process(_ byte: UInt8, output: inout Data, titles: inout [String]) {
        let esc: UInt8 = 0x1B
        switch state {
        case .ground:
            if byte == esc {
                state = .escape
            } else {
                output.append(byte)
            }
        case .escape:
            if byte == UInt8(ascii: "k") {
                state = .title
                title.removeAll(keepingCapacity: true)
            } else if byte == esc {
                // `ESC ESC`: the first is complete on its own.
                output.append(esc)
            } else {
                state = .ground
                output.append(esc)
                output.append(byte)
            }
        case .title:
            if byte == esc {
                state = .titleEscape
            } else if byte == 0x07 {
                finishTitle(&titles)
            } else if title.count < Self.maxTitleBytes {
                title.append(byte)
            }
        case .titleEscape:
            finishTitle(&titles)
            // `ESC \` is the terminator. Any other byte after ESC ends the
            // title too and begins a new escape sequence.
            if byte != UInt8(ascii: "\\") {
                state = .escape
                process(byte, output: &output, titles: &titles)
            }
        }
    }

    private mutating func finishTitle(_ titles: inout [String]) {
        titles.append(String(decoding: title, as: UTF8.self))
        title.removeAll(keepingCapacity: true)
        state = .ground
    }
}
