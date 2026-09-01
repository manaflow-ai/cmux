import Foundation

/// Incremental, line-oriented parser for the tmux control protocol.
///
/// Feed it raw gateway stdout via ``consume(_:)``; it buffers partial lines and
/// returns decoded ``TmuxControlModeEvent`` values. It is a pure value type with
/// no I/O, so it is fully unit-testable.
public struct TmuxControlModeParser: Sendable {
    public static let defaultMaximumBufferedLineBytes = 1_048_576
    public static let defaultMaximumCommandBlockBytes = 16_777_216

    private let maxBufferedLineBytes: Int
    private let maxCommandBlockBytes: Int
    private let stripDCSFraming: Bool
    private var lineBuffer: [UInt8] = []
    private var dcsPreambleBuffer: [UInt8] = []

    private enum DCSFramingState: Sendable {
        case awaitingEnter
        case inside
        case closed
    }

    private var dcsFramingState: DCSFramingState

    // Command-block state. While `inBlock` is true, every non-fence line is
    // buffered as command output (notifications never appear inside a block).
    private var inBlock = false
    private var blockFence: Fence?
    private var blockOutput: [String] = []
    private var blockBufferedBytes = 0
    private var failed = false

    /// The three fields on a guard line are one identity. The command number
    /// alone is not enough to prove that `%end` belongs to the current
    /// `%begin`, especially after a reconnect or a malformed transport.
    private struct Fence: Equatable, Sendable {
        let time: Int64
        let number: Int
        let flags: Int
    }

    public init(
        maxBufferedLineBytes: Int = Self.defaultMaximumBufferedLineBytes,
        maxCommandBlockBytes: Int = Self.defaultMaximumCommandBlockBytes,
        stripDCSFraming: Bool = false
    ) {
        self.maxBufferedLineBytes = max(1, maxBufferedLineBytes)
        self.maxCommandBlockBytes = max(1, maxCommandBlockBytes)
        self.stripDCSFraming = stripDCSFraming
        self.dcsFramingState = stripDCSFraming ? .awaitingEnter : .inside
    }

    /// Consume a chunk of gateway output and return any events it completes.
    public mutating func consume(_ bytes: [UInt8]) -> [TmuxControlModeEvent] {
        guard !bytes.isEmpty, !failed else { return [] }
        var events: [TmuxControlModeEvent] = []
        let protocolBytes: ArraySlice<UInt8>
        if stripDCSFraming {
            switch dcsFramingState {
            case .awaitingEnter:
                dcsPreambleBuffer.append(contentsOf: bytes)
                if let enterIndex = Self.index(of: Self.dcsEnterSequence, in: dcsPreambleBuffer) {
                    let protocolStart = enterIndex + Self.dcsEnterSequence.count
                    protocolBytes = dcsPreambleBuffer[protocolStart...]
                    dcsPreambleBuffer.removeAll(keepingCapacity: false)
                    dcsFramingState = .inside
                } else {
                    guard dcsPreambleBuffer.count <= maxBufferedLineBytes else {
                        resetAfterProtocolError()
                        return [.protocolError(
                            reason: "tmux control stream did not enter DCS framing within "
                                + String(maxBufferedLineBytes) + " bytes"
                        )]
                    }
                    return []
                }
            case .inside:
                protocolBytes = bytes[...]
            case .closed:
                // `script(1)` and SSH may write transport diagnostics after
                // tmux closes its DCS envelope. They are outside the control
                // protocol and cannot become terminal output.
                return []
            }
        } else {
            protocolBytes = bytes[...]
        }

        for byte in protocolBytes {
            lineBuffer.append(byte)
            guard lineBuffer.count <= maxBufferedLineBytes else {
                resetAfterProtocolError()
                events.append(.protocolError(
                    reason: "tmux control line exceeded " + String(maxBufferedLineBytes) + " bytes"
                ))
                return events
            }
            guard byte == 0x0A /* \n */ else { continue }
            var line = Array(lineBuffer.dropLast())
            // Strip a trailing CR (tmux uses \r\n on some lines).
            if line.last == 0x0D /* \r */ { line.removeLast() }
            lineBuffer.removeAll(keepingCapacity: true)
            processLine(line, into: &events)
            if failed { return events }
        }
        return events
    }

    /// Flush a final control line when the transport reaches EOF without a
    /// newline. tmux normally terminates every record with LF, but a pty or an
    /// SSH disconnect can cut the final `%exit` record at the boundary. A
    /// partial command block is never accepted because its command/result
    /// correlation is no longer provable.
    public mutating func finish() -> [TmuxControlModeEvent] {
        guard !failed else { return [] }
        var events: [TmuxControlModeEvent] = []
        if stripDCSFraming, dcsFramingState == .awaitingEnter {
            resetAfterProtocolError()
            return [.protocolError(reason: "tmux control stream ended before DCS framing began")]
        }

        // tmux normally writes the DCS string terminator as a standalone
        // `ESC \\` after the `%exit` line. It therefore cannot be handled by
        // the line parser above. Consume that marker at EOF, including when
        // the marker arrived in a separate transport chunk, before deciding
        // that framing was truncated. A raw `%output` record is exempt: tmux
        // carries pane bytes on that line and an OSC terminator is valid pane
        // data, so it must remain terminal output.
        if stripDCSFraming, dcsFramingState == .inside,
           let closeIndex = Self.index(of: Self.dcsExitSequence, in: lineBuffer),
           !Self.isRawOutputLine(lineBuffer) {
            let prefix = Array(lineBuffer[..<closeIndex])
            lineBuffer.removeAll(keepingCapacity: false)
            if !prefix.isEmpty {
                processLine(prefix, into: &events)
            }
            if !failed {
                dcsFramingState = .closed
            }
        }
        if !lineBuffer.isEmpty {
            let line = lineBuffer
            lineBuffer.removeAll(keepingCapacity: true)
            processLine(line, into: &events)
        }
        guard !failed, !inBlock else {
            resetAfterProtocolError()
            events.append(.protocolError(reason: "tmux control stream ended inside a command block"))
            return events
        }
        if stripDCSFraming, dcsFramingState != .closed {
            resetAfterProtocolError()
            events.append(.protocolError(reason: "tmux control stream ended before DCS framing closed"))
        }
        return events
    }

    private mutating func processLine(_ rawLine: [UInt8], into events: inout [TmuxControlModeEvent]) {
        var line = rawLine
        // `finish()` can deliver a final record without LF. Apply the same
        // CRLF normalization used by `consume()` so an EOF after `%exit\r`
        // does not turn the carriage return into part of the reason.
        if line.last == 0x0D /* \r */ { line.removeLast() }
        if stripDCSFraming, !inBlock {
            // `-CC` wraps the control stream in DEC DCS framing. The opening
            // sequence is consumed before line parsing. The closing ST can
            // share `%exit` or arrive on its own line. Never strip ST from a
            // raw output record because tmux pane data has separate escaping.
            // `%output` carries the pane's raw bytes after its header. An OSC
            // string terminator (`ESC \\`) is valid pane data, so never strip
            // it from that notification. The DCS terminator belongs to the
            // surrounding control stream and is removed only from textual
            // notifications.
            let isRawOutput = line.starts(with: Array("%output ".utf8))
                || line.starts(with: Array("%extended-output ".utf8))
            if !isRawOutput {
                if let closeIndex = Self.index(of: Self.dcsExitSequence, in: line) {
                    line = Array(line[..<closeIndex])
                    dcsFramingState = .closed
                }
            }
        }
        if line.isEmpty, !inBlock { return }
        if inBlock {
            if let fence = Self.parseFence(line, prefix: "%end") {
                if fence == blockFence {
                    finishBlock(isError: false, into: &events)
                    return
                }
                // A valid-looking guard for another command is payload. tmux
                // permits command output to begin with `%end` or `%error`; it
                // is the complete matching metadata, not the prefix, that
                // closes this block.
            } else if let fence = Self.parseFence(line, prefix: "%error") {
                if fence == blockFence {
                    finishBlock(isError: true, into: &events)
                    return
                }
            }
            // Verbatim command output line.
            guard blockBufferedBytes + line.count + 1 <= maxCommandBlockBytes else {
                resetAfterProtocolError()
                events.append(.protocolError(
                    reason: "tmux control block exceeded " + String(maxCommandBlockBytes) + " bytes"
                ))
                return
            }
            blockBufferedBytes += line.count + 1
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
            guard let fence = Self.parseFence(line, prefix: "%begin") else {
                resetAfterProtocolError()
                events.append(.protocolError(reason: "malformed tmux %begin fence"))
                return
            }
            inBlock = true
            blockOutput = []
            blockBufferedBytes = 0
            blockFence = fence
            events.append(.begin(number: fence.number))
            return
        }
        decodeNotification(line: line, text: text, into: &events)
    }

    private mutating func finishBlock(isError: Bool, into events: inout [TmuxControlModeEvent]) {
        let number = blockFence?.number ?? 0
        events.append(.commandResult(number: number, output: blockOutput, isError: isError))
        inBlock = false
        blockFence = nil
        blockOutput = []
        blockBufferedBytes = 0
    }

    private mutating func resetAfterProtocolError() {
        failed = true
        lineBuffer.removeAll(keepingCapacity: false)
        dcsPreambleBuffer.removeAll(keepingCapacity: false)
        inBlock = false
        blockFence = nil
        blockOutput.removeAll(keepingCapacity: false)
        blockBufferedBytes = 0
    }

    private mutating func decodeNotification(line: [UInt8], text: String, into events: inout [TmuxControlModeEvent]) {
        // %output and %extended-output carry octal-escaped binary data after the
        // pane id, so they are decoded at the byte level. Everything else is
        // plain ASCII tokens.
        if line.starts(with: Array("%output ".utf8)) {
            guard let (pane, dataBytes) = Self.paneAndData(line, prefixLength: 8),
                  Self.isPaneID(pane) else {
                failProtocol("malformed tmux %output notification", into: &events)
                return
            }
            events.append(.output(paneID: pane, bytes: Self.unescapeOutput(dataBytes)))
            return
        }
        if line.starts(with: Array("%extended-output ".utf8)) {
            // %extended-output %<pane> <age> : <data>
            guard let (pane, rest) = Self.paneAndData(line, prefixLength: 17),
                  Self.isPaneID(pane),
                  let colon = rest.firstIndex(of: 0x3A) /* : */ else {
                failProtocol("malformed tmux %extended-output notification", into: &events)
                return
            }
            // The metadata is an unsigned age followed by a colon. Parse it
            // before accepting the payload so a truncated record cannot be
            // mistaken for terminal bytes.
            // tmux currently emits only the numeric age, but the protocol
            // reserves the remaining metadata fields for future versions.
            // Validate the required first field and ignore later fields so a
            // valid future record does not get mistaken for terminal bytes.
            let metadata = rest[..<colon]
                .split(whereSeparator: { $0 == 0x20 || $0 == 0x09 }, omittingEmptySubsequences: true)
            guard let age = metadata.first,
                  UInt64(String(decoding: age, as: UTF8.self)) != nil else {
                failProtocol("malformed tmux %extended-output age", into: &events)
                return
            }
            // Data begins one byte after the colon's optional trailing space.
            var dataStart = rest.index(after: colon)
            while dataStart < rest.endIndex,
                  rest[dataStart] == 0x20 || rest[dataStart] == 0x09 {
                dataStart = rest.index(after: dataStart)
            }
            let dataBytes = rest[dataStart..<rest.endIndex]
            events.append(.output(paneID: pane, bytes: Self.unescapeOutput(dataBytes)))
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
        case "subscription-changed":
            guard let name = args.first else { return }
            // tmux inserts client/window/pane metadata before ` : ` and the
            // subscribed format after it. Preserve the value verbatim.
            let value = text.range(of: " : ").map { String(text[$0.upperBound...]) } ?? ""
            events.append(.subscriptionChanged(name: name, value: value))
        case "exit":
            events.append(.exit(reason: args.isEmpty ? nil : args.joined(separator: " ")))
        case "client-detached":
            events.append(.clientDetached)
        default:
            events.append(.notification(name: name, arguments: args))
        }
    }

    private mutating func failProtocol(
        _ reason: String,
        into events: inout [TmuxControlModeEvent]
    ) {
        resetAfterProtocolError()
        events.append(.protocolError(reason: reason))
    }

    // MARK: - Static helpers

    private static func parseFence(_ line: [UInt8], prefix: String) -> Fence? {
        let prefixBytes = Array((prefix + " ").utf8)
        guard line.starts(with: prefixBytes) else { return nil }
        let text = String(decoding: line, as: UTF8.self)
        // "%end <time> <number> <flags>"
        let parts = text.split(separator: " ")
        guard parts.count == 4,
              let time = Int64(parts[1]),
              let number = Int(parts[2]),
              let flags = Int(parts[3])
        else { return nil }
        return Fence(time: time, number: number, flags: flags)
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

    private static func isPaneID(_ pane: String) -> Bool {
        guard pane.first == "%", pane.count > 1 else { return false }
        let digits = pane.dropFirst().utf8
        return !digits.isEmpty && digits.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
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
                    if value <= 0xFF {
                        out.append(UInt8(value))
                        i = bytes.index(i, offsetBy: 4)
                        continue
                    }
                    // `\\400` through `\\777` are not byte escapes. Keep
                    // the source bytes intact instead of truncating them,
                    // which would silently corrupt an invalid stream.
                }
            }
            out.append(b)
            i = bytes.index(after: i)
        }
        return out
    }

    private static func isOctalDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }

    private static func isRawOutputLine(_ line: [UInt8]) -> Bool {
        line.starts(with: Array("%output ".utf8))
            || line.starts(with: Array("%extended-output ".utf8))
    }

    private static let dcsEnterSequence: [UInt8] = [
        0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70,
    ] // ESC P 1000 p

    private static let dcsExitSequence: [UInt8] = [0x1B, 0x5C] // ST

    private static func index(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lastStart = haystack.count - needle.count
        for start in 0...lastStart where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

}
