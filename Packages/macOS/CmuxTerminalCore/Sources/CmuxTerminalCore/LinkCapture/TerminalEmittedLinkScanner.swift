public import Foundation

/// Incrementally captures OSC-8 and plain URLs from raw terminal output bytes.
///
/// The scanner is designed for Ghostty's synchronous PTY tee callback. It keeps
/// only a bounded logical-line buffer, ignores terminal control sequences, and
/// returns captured links in the same call that observes their terminating
/// boundary.
public struct TerminalEmittedLinkScanner: Sendable {
    private static let maximumLogicalLineBytes = 4_096
    private static let maximumOSC8URIBytes = 2_048
    private static let maximumOSCCommandBytes = 16
    private static let maximumCSIParameterBytes = 12

    private var escapeState: TerminalLinkEscapeState = .none
    private var osc8State: TerminalOSC8State = .none
    private var osc8URIBuffer: [UInt8] = []
    private var csiParameterBytes: [UInt8] = []
    private var csiParameterOverflowed = false
    private var logicalLine: [UInt8] = []
    private var logicalLineConsumedBytes = 0
    private var logicalLineOverflowed = false
    private var logicalLinePendingCarriageReturn = false

    /// Creates an empty terminal-emitted-link scanner.
    public init() {
        logicalLine.reserveCapacity(256)
        osc8URIBuffer.reserveCapacity(256)
    }

    /// Clears all incremental parser state.
    public mutating func reset() {
        escapeState = .none
        osc8State = .none
        osc8URIBuffer.removeAll(keepingCapacity: true)
        csiParameterBytes.removeAll(keepingCapacity: true)
        csiParameterOverflowed = false
        resetLogicalLine()
    }

    /// Consumes one data chunk and returns links completed by this chunk.
    ///
    /// - Parameter data: Raw bytes read from the PTY.
    /// - Returns: Captured URLs whose OSC-8 sequence or logical line completed
    ///   during this call.
    @discardableResult
    public mutating func consume(_ data: Data) -> [TerminalCapturedLink] {
        data.withUnsafeBytes { rawBuffer in
            consume(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    /// Consumes one byte array and returns links completed by this chunk.
    ///
    /// - Parameter bytes: Raw bytes read from the PTY.
    /// - Returns: Captured URLs whose OSC-8 sequence or logical line completed
    ///   during this call.
    @discardableResult
    public mutating func consume(_ bytes: [UInt8]) -> [TerminalCapturedLink] {
        bytes.withUnsafeBufferPointer { consume($0) }
    }

    /// Consumes one borrowed byte chunk and returns links completed by this chunk.
    ///
    /// - Parameter bytes: Raw bytes read from the PTY.
    /// - Returns: Captured URLs whose OSC-8 sequence or logical line completed
    ///   during this call.
    @discardableResult
    public mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) -> [TerminalCapturedLink] {
        guard !bytes.isEmpty else { return [] }
        var captured: [TerminalCapturedLink] = []
        captured.reserveCapacity(1)

        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if canSkipPrintableRun(startingWith: byte) {
                var cursor = index + 1
                while cursor < bytes.endIndex {
                    let next = bytes[cursor]
                    if next < 0x20 || next == 0x7F || next == UInt8(ascii: "h") ||
                        next == UInt8(ascii: "H") || next == UInt8(ascii: "f") ||
                        next == UInt8(ascii: "F") {
                        break
                    }
                    cursor += 1
                }
                advanceLogicalLineConsumption(by: cursor - index)
                index = cursor
                continue
            }
            consumeOSC8(byte, captured: &captured)
            consumeLogicalLine(byte, captured: &captured)
            index += 1
        }
        return captured
    }

    private func canSkipPrintableRun(startingWith byte: UInt8) -> Bool {
        guard byte >= 0x20, byte != 0x7F,
              escapeState == .none,
              osc8State == .none,
              !logicalLinePendingCarriageReturn,
              logicalLine.isEmpty else {
            return false
        }
        return byte != UInt8(ascii: "h") &&
            byte != UInt8(ascii: "H") &&
            byte != UInt8(ascii: "f") &&
            byte != UInt8(ascii: "F")
    }

    private mutating func consumeOSC8(
        _ byte: UInt8,
        captured: inout [TerminalCapturedLink]
    ) {
        switch osc8State {
        case .none:
            if byte == 0x1B { osc8State = .escape }
        case .escape:
            osc8State = byte == UInt8(ascii: "]") ? .command([]) : .none
        case .command(var command):
            if byte == UInt8(ascii: ";") {
                osc8State = .params(command: command)
            } else if byte == 0x07 {
                osc8State = .none
            } else if byte == 0x1B {
                osc8State = .ignoredEscape
            } else if command.count < Self.maximumOSCCommandBytes {
                command.append(byte)
                osc8State = .command(command)
            } else {
                osc8State = .ignored
            }
        case .params(let command):
            if byte == UInt8(ascii: ";") {
                if command == [UInt8(ascii: "8")] {
                    osc8URIBuffer.removeAll(keepingCapacity: true)
                    osc8State = .uri(overflowed: false)
                } else {
                    osc8State = .ignored
                }
            } else if byte == 0x07 {
                osc8State = .none
            } else if byte == 0x1B {
                osc8State = .ignoredEscape
            }
        case .uri(let overflowed):
            if byte == 0x07 {
                finishOSC8URI(overflowed: overflowed, captured: &captured)
            } else if byte == 0x1B {
                osc8State = .uriEscape(overflowed: overflowed)
            } else if !overflowed, osc8URIBuffer.count < Self.maximumOSC8URIBytes {
                osc8URIBuffer.append(byte)
                osc8State = .uri(overflowed: false)
            } else {
                osc8State = .uri(overflowed: true)
            }
        case .uriEscape(let overflowed):
            if byte == UInt8(ascii: "\\") {
                finishOSC8URI(overflowed: overflowed, captured: &captured)
            } else {
                var didOverflow = overflowed
                if !didOverflow, osc8URIBuffer.count + 2 <= Self.maximumOSC8URIBytes {
                    osc8URIBuffer.append(0x1B)
                    osc8URIBuffer.append(byte)
                } else {
                    didOverflow = true
                }
                osc8State = .uri(overflowed: didOverflow)
            }
        case .ignored:
            if byte == 0x07 {
                osc8State = .none
            } else if byte == 0x1B {
                osc8State = .ignoredEscape
            }
        case .ignoredEscape:
            osc8State = byte == UInt8(ascii: "\\") ? .none : .ignored
        }
    }

    private mutating func finishOSC8URI(
        overflowed: Bool,
        captured: inout [TerminalCapturedLink]
    ) {
        defer {
            osc8State = .none
            osc8URIBuffer.removeAll(keepingCapacity: true)
        }
        guard !overflowed, !osc8URIBuffer.isEmpty,
              let url = String(bytes: osc8URIBuffer, encoding: .utf8),
              isAllowedScheme(url) else {
            return
        }
        captured.append(TerminalCapturedLink(url: url, source: .osc8))
    }

    private mutating func consumeLogicalLine(
        _ byte: UInt8,
        captured: inout [TerminalCapturedLink]
    ) {
        switch escapeState {
        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                escapeState = .csi
            case UInt8(ascii: "]"):
                escapeState = .osc
            default:
                escapeState = .none
            }
            return
        case .csi:
            if (0x40...0x7E).contains(byte) {
                escapeState = .none
                handleCSITerminator(byte)
            } else if csiParameterBytes.count < Self.maximumCSIParameterBytes {
                csiParameterBytes.append(byte)
            } else {
                csiParameterOverflowed = true
            }
            return
        case .osc:
            if byte == 0x07 {
                escapeState = .none
            } else if byte == 0x1B {
                escapeState = .oscEscape
            }
            return
        case .oscEscape:
            escapeState = byte == UInt8(ascii: "\\") ? .none : .osc
            return
        case .none:
            break
        }

        if logicalLinePendingCarriageReturn {
            if byte == 0x0A {
                scanLogicalLine(captured: &captured)
                resetLogicalLine()
                return
            }
            resetLogicalLine()
        }

        switch byte {
        case 0x1B:
            escapeState = .escape
            csiParameterBytes.removeAll(keepingCapacity: true)
            csiParameterOverflowed = false
        case 0x0A:
            scanLogicalLine(captured: &captured)
            resetLogicalLine()
        case 0x0D:
            logicalLinePendingCarriageReturn = true
        case 0x08, 0x7F:
            if !logicalLineOverflowed {
                _ = logicalLine.popLast()
            }
        case 0x20...0x7E, 0x80...0xFF:
            appendToLogicalLine(byte)
        default:
            break
        }
    }

    private mutating func appendToLogicalLine(_ byte: UInt8) {
        guard !logicalLineOverflowed else { return }
        advanceLogicalLineConsumption(by: 1)
        guard !logicalLineOverflowed else {
            logicalLine.removeAll(keepingCapacity: true)
            return
        }
        logicalLine.append(byte)
    }

    private mutating func advanceLogicalLineConsumption(by byteCount: Int) {
        guard !logicalLineOverflowed else { return }
        logicalLineConsumedBytes += byteCount
        guard logicalLineConsumedBytes <= Self.maximumLogicalLineBytes else {
            logicalLine.removeAll(keepingCapacity: true)
            logicalLineOverflowed = true
            return
        }
    }

    private mutating func handleCSITerminator(_ terminator: UInt8) {
        defer {
            csiParameterBytes.removeAll(keepingCapacity: true)
            csiParameterOverflowed = false
        }
        guard !csiParameterOverflowed else { return }
        switch terminator {
        case UInt8(ascii: "G"):
            guard csiParameterBytes.isEmpty ||
                csiParameterBytes == [UInt8(ascii: "1")] ||
                csiParameterBytes == [UInt8(ascii: "0")] else { return }
            resetLogicalLine()
        case UInt8(ascii: "K"):
            guard csiParameterBytes == [UInt8(ascii: "2")] else { return }
            resetLogicalLine()
        default:
            break
        }
    }

    private mutating func scanLogicalLine(captured: inout [TerminalCapturedLink]) {
        guard !logicalLineOverflowed,
              let line = String(bytes: logicalLine, encoding: .utf8) else {
            return
        }
        for url in detectURLs(in: line) {
            captured.append(TerminalCapturedLink(url: url, source: .detected))
        }
    }

    private mutating func resetLogicalLine() {
        logicalLine.removeAll(keepingCapacity: true)
        logicalLineConsumedBytes = 0
        logicalLineOverflowed = false
        logicalLinePendingCarriageReturn = false
    }

    /// Detects plain http(s) and file URLs in one logical line.
    ///
    /// - Parameter line: One control-stripped terminal logical line.
    /// - Returns: URL substrings in encounter order.
    public func detectURLs(in line: String) -> [String] {
        guard !line.isEmpty else { return [] }
        var results: [String] = []
        var searchStart = line.startIndex
        while searchStart < line.endIndex {
            guard let match = nextSchemeMatch(in: line, from: searchStart) else { break }
            let end = urlEnd(in: line, from: match)
            var candidate = String(line[match..<end])
            candidate = trimTrailingPunctuation(candidate)
            if isAcceptedDetectedURL(candidate) {
                results.append(candidate)
            }
            searchStart = end > match ? end : line.index(after: match)
        }
        return results
    }

    private func nextSchemeMatch(in line: String, from start: String.Index) -> String.Index? {
        let schemes = ["https://", "http://", "file://"]
        var best: String.Index?
        for scheme in schemes {
            if let range = line.range(of: scheme, options: [.caseInsensitive], range: start..<line.endIndex),
               best == nil || range.lowerBound < best! {
                best = range.lowerBound
            }
        }
        return best
    }

    private func urlEnd(in line: String, from start: String.Index) -> String.Index {
        var index = start
        var parenBalance = 0
        var bracketBalance = 0
        while index < line.endIndex {
            let character = line[index]
            if character.isWhitespace || character == "\"" || character == "'" ||
                character == "<" || character == ">" || character == "`" {
                break
            }
            if character == "(" {
                parenBalance += 1
            } else if character == ")" {
                if parenBalance == 0 { break }
                parenBalance -= 1
            } else if character == "[" {
                bracketBalance += 1
            } else if character == "]" {
                if bracketBalance == 0 { break }
                bracketBalance -= 1
            }
            index = line.index(after: index)
        }
        return index
    }

    private func trimTrailingPunctuation(_ raw: String) -> String {
        var result = raw
        while let last = result.last,
              ".,;:!?\"'".contains(last) {
            result.removeLast()
        }
        while result.last == ")" && closingCharacterIsUnbalanced(")", in: result) {
            result.removeLast()
        }
        while result.last == "]" && closingCharacterIsUnbalanced("]", in: result) {
            result.removeLast()
        }
        return result
    }

    private func closingCharacterIsUnbalanced(_ closing: Character, in string: String) -> Bool {
        let opening: Character = closing == ")" ? "(" : "["
        var balance = 0
        for character in string {
            if character == opening { balance += 1 }
            if character == closing { balance -= 1 }
        }
        return balance < 0
    }

    private func isAcceptedDetectedURL(_ candidate: String) -> Bool {
        guard isAllowedScheme(candidate) else { return false }
        if candidate.lowercased().hasPrefix("file://") {
            return candidate.count > "file://".count
        }
        let hostPolicy = CapturedLinkHostPolicy()
        guard let hostKey = hostPolicy.hostKey(for: candidate) else { return false }
        let host = hostPolicy.hostPart(of: hostKey)
        return host == "localhost" ||
            host.contains(".") ||
            host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil ||
            host.contains(":") ||
            hostKey.contains(":")
    }

    private func isAllowedScheme(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("file://")
    }
}
