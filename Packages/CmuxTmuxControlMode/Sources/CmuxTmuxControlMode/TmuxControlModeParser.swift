import Foundation

/// Incremental, line-oriented parser for the `tmux -CC` control protocol.
///
/// Feed it raw gateway stdout via ``consume(_:)``; it buffers partial lines and
/// returns decoded ``TmuxControlModeEvent`` values. It is a pure value type with
/// no I/O, so it is fully unit-testable.
public struct TmuxControlModeParser: Sendable {
    private var lineBuffer: [UInt8] = []

    // Command-block state. While `inBlock` is true, every non-fence line is
    // buffered as command output (notifications never appear inside a block).
    private var inBlock = false
    private var blockNumber = 0
    private var blockOutput: [String] = []

    public init() {}

    /// Consume a chunk of gateway output and return any events it completes.
    public mutating func consume(_ bytes: [UInt8]) -> [TmuxControlModeEvent] {
        guard !bytes.isEmpty else { return [] }
        lineBuffer.append(contentsOf: bytes)

        var events: [TmuxControlModeEvent] = []
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) /* \n */ {
            var line = Array(lineBuffer[lineBuffer.startIndex..<newlineIndex])
            // Strip a trailing CR (tmux uses \r\n on some lines).
            if line.last == 0x0D /* \r */ { line.removeLast() }
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            processLine(line, into: &events)
        }
        return events
    }

    private mutating func processLine(_ rawLine: [UInt8], into events: inout [TmuxControlModeEvent]) {
        // Outside a block, strip tmux's control-mode introducer/terminator,
        // which it emits on the wire fused to the next token, e.g.
        // "\u{1b}P1000p%begin …" on entry and a trailing ST ("\u{1b}\\") on exit.
        let line = inBlock ? rawLine : Self.stripControlIntroducers(rawLine)
        if inBlock {
            if line.starts(with: Array("%end ".utf8)) || lineEquals(line, "%end") {
                finishBlock(isError: false, into: &events)
                return
            }
            if line.starts(with: Array("%error ".utf8)) || lineEquals(line, "%error") {
                finishBlock(isError: true, into: &events)
                return
            }
            // Verbatim command output line.
            blockOutput.append(String(decoding: line, as: UTF8.self))
            return
        }

        guard line.first == 0x25 /* % */ else {
            // Outside a block, non-% lines are not part of the protocol
            // (e.g. the DCS sent on entering control mode). Ignore them.
            return
        }

        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix("%begin ") {
            inBlock = true
            blockOutput = []
            blockNumber = Self.commandNumber(fromFence: text)
            events.append(.begin(number: blockNumber))
            return
        }
        decodeNotification(line: line, text: text, into: &events)
    }

    private mutating func finishBlock(isError: Bool, into events: inout [TmuxControlModeEvent]) {
        events.append(.commandResult(number: blockNumber, output: blockOutput, isError: isError))
        inBlock = false
        blockOutput = []
    }

    private func decodeNotification(line: [UInt8], text: String, into events: inout [TmuxControlModeEvent]) {
        // %output and %extended-output carry octal-escaped binary data after the
        // pane id, so they are decoded at the byte level. Everything else is
        // plain ASCII tokens.
        if line.starts(with: Array("%output ".utf8)) {
            if let (pane, dataBytes) = Self.paneAndData(line, prefixLength: 8) {
                events.append(.output(paneID: pane, bytes: Self.unescapeOutput(dataBytes)))
            }
            return
        }
        if line.starts(with: Array("%extended-output ".utf8)) {
            // %extended-output %<pane> <age> : <data>
            if let (pane, rest) = Self.paneAndData(line, prefixLength: 17),
               let colon = rest.firstIndex(of: 0x3A) /* : */ {
                // Data begins one byte after the colon's trailing space.
                var dataStart = rest.index(after: colon)
                if dataStart < rest.endIndex, rest[dataStart] == 0x20 { dataStart = rest.index(after: dataStart) }
                let dataBytes = rest[dataStart..<rest.endIndex]
                events.append(.output(paneID: pane, bytes: Self.unescapeOutput(dataBytes)))
            }
            return
        }

        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = tokens.first else { return }
        let name = String(head.dropFirst()) // drop leading '%'
        let args = Array(tokens.dropFirst())

        switch name {
        case "layout-change":
            // %layout-change <window> <layout> <visible-layout> <flags>
            events.append(.layoutChange(
                window: args.first ?? "",
                layout: args.count > 1 ? args[1] : "",
                visibleLayout: args.count > 2 ? args[2] : nil,
                flags: args.count > 3 ? args[3] : nil
            ))
        case "window-add":
            events.append(.windowAdd(window: args.first ?? ""))
        case "window-close", "unlinked-window-close":
            events.append(.windowClose(window: args.first ?? ""))
        case "window-renamed":
            events.append(.windowRenamed(window: args.first ?? "", name: args.count > 1 ? tokens.dropFirst(2).joined(separator: " ") : ""))
        case "window-pane-changed":
            events.append(.windowPaneChanged(window: args.first ?? "", pane: args.count > 1 ? args[1] : ""))
        case "session-changed":
            events.append(.sessionChanged(session: args.first ?? "", name: args.count > 1 ? args[1] : ""))
        case "sessions-changed":
            events.append(.sessionsChanged)
        case "pane-mode-changed":
            events.append(.paneModeChanged(pane: args.first ?? ""))
        case "exit":
            events.append(.exit(reason: args.isEmpty ? nil : args.joined(separator: " ")))
        case "client-detached":
            events.append(.clientDetached)
        default:
            events.append(.notification(name: name, arguments: args))
        }
    }

    // MARK: - Static helpers

    private static func commandNumber(fromFence text: String) -> Int {
        // "%begin <time> <number> <flags>"
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return 0 }
        return Int(parts[2]) ?? 0
    }

    /// Split a `%output`/`%extended-output` line into the pane id and the
    /// remaining bytes (data, or `age : data`). `prefixLength` is the byte
    /// length of the directive plus its trailing space.
    private static func paneAndData(_ line: [UInt8], prefixLength: Int) -> (pane: String, rest: ArraySlice<UInt8>)? {
        guard line.count > prefixLength else { return nil }
        let afterPrefix = line[(line.startIndex + prefixLength)...]
        guard let spaceIndex = afterPrefix.firstIndex(of: 0x20) else { return nil }
        let paneBytes = afterPrefix[afterPrefix.startIndex..<spaceIndex]
        let pane = String(decoding: paneBytes, as: UTF8.self)
        let rest = afterPrefix[afterPrefix.index(after: spaceIndex)...]
        return (pane, rest)
    }

    /// Reverse tmux's control-mode escaping: a backslash followed by exactly
    /// three octal digits encodes one raw byte (e.g. `\033` -> 0x1B, `\134` ->
    /// `\`). Anything else is passed through verbatim.
    static func unescapeOutput(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let b = bytes[i]
            if b == 0x5C /* \ */ {
                let d0 = bytes.index(i, offsetBy: 1, limitedBy: bytes.endIndex)
                let d1 = bytes.index(i, offsetBy: 2, limitedBy: bytes.endIndex)
                let d2 = bytes.index(i, offsetBy: 3, limitedBy: bytes.endIndex)
                if let d0, let d1, let d2, d0 < bytes.endIndex, d1 < bytes.endIndex, d2 < bytes.endIndex,
                   isOctalDigit(bytes[d0]), isOctalDigit(bytes[d1]), isOctalDigit(bytes[d2]) {
                    let value = (Int(bytes[d0] - 0x30) << 6) | (Int(bytes[d1] - 0x30) << 3) | Int(bytes[d2] - 0x30)
                    out.append(UInt8(truncatingIfNeeded: value))
                    i = bytes.index(i, offsetBy: 4)
                    continue
                }
            }
            out.append(b)
            i = bytes.index(after: i)
        }
        return out
    }

    private static func isOctalDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }

    /// Remove tmux's control-mode introducer `ESC P 1 0 0 0 p` (entry) and the
    /// `ESC \` string terminator (exit) wherever they sit at a line boundary.
    /// tmux emits the entry sequence fused to the first `%begin`.
    static func stripControlIntroducers(_ input: [UInt8]) -> [UInt8] {
        let dcs: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70] // ESC P 1 0 0 0 p
        let st: [UInt8] = [0x1B, 0x5C] // ESC backslash
        var line = input
        var changed = true
        while changed {
            changed = false
            if line.starts(with: dcs) { line.removeFirst(dcs.count); changed = true }
            if line.starts(with: st) { line.removeFirst(st.count); changed = true }
        }
        if line.count >= st.count, line.suffix(st.count).elementsEqual(st) {
            line.removeLast(st.count)
        }
        return line
    }

    private func lineEquals(_ line: [UInt8], _ s: String) -> Bool {
        line.elementsEqual(Array(s.utf8))
    }
}
