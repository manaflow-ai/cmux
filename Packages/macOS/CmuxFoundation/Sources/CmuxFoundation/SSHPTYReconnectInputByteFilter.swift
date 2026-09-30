public import Foundation

/// Removes terminal probe and OSC 52 clipboard replies queued while an SSH PTY
/// bridge reconnects.
///
/// Filtering remains active only while input consists entirely of recognized
/// terminal replies or EOT bytes. The first ordinary key byte ends filtering,
/// and that byte plus all later input passes through unchanged.
public struct SSHPTYReconnectInputByteFilter: Sendable {
    private static let escape: UInt8 = 0x1B
    private static let endOfTransmission: UInt8 = 0x04
    private static let bell: UInt8 = 0x07
    private static let leftBracket: UInt8 = 0x5B
    private static let rightBracket: UInt8 = 0x5D
    private static let dcs: UInt8 = 0x50
    private static let backslash: UInt8 = 0x5C
    private static let semicolon: UInt8 = 0x3B
    private static let questionMark: UInt8 = 0x3F
    private static let dollar: UInt8 = 0x24
    private static let maxPendingProbeBytes = 512

    private enum SequenceMatch {
        case strip(length: Int)
        case incomplete
        case passThrough
        /// An OSC 52 clipboard reply whose terminator has not arrived yet.
        case unterminatedClipboardReply
    }

    private var isFiltering: Bool
    private var pending = [UInt8]()
    /// Whether the rest of an OSC 52 clipboard reply is being discarded.
    ///
    /// Clipboard replies carry the user's clipboard and can exceed the
    /// pending-probe bound, so their bytes are dropped as they stream in
    /// instead of being buffered and later flushed to the remote PTY. See
    /// ``hasPendingInput`` for how long discarding may last.
    private var discardingClipboardReply = false

    /// Creates a reconnect-input filter.
    ///
    /// - Parameter enabled: Whether recognized terminal replies should be
    ///   removed until the first ordinary input byte arrives.
    public init(enabled: Bool) {
        isFiltering = enabled
    }

    /// Filters one input chunk while preserving non-probe bytes in order.
    ///
    /// The method may retain an incomplete escape sequence until a later chunk
    /// supplies its terminator. Call ``finish()`` when no continuation can
    /// arrive, or ``stopFiltering()`` when the bridge is ready for live input.
    ///
    /// - Parameter data: Raw bytes read from the reconnecting terminal.
    /// - Returns: Bytes that should be forwarded to the remote PTY.
    public mutating func filter(_ data: Data) -> Data {
        guard isFiltering, !data.isEmpty else {
            return data
        }

        var bytes = pending
        pending.removeAll(keepingCapacity: true)
        bytes.append(contentsOf: data)

        var output = Data()
        var index = 0
        if discardingClipboardReply {
            guard let end = Self.stringTerminatorEnd(in: bytes, from: 0) else {
                retainTrailingEscapeOfDiscardedReply(bytes)
                return output
            }
            discardingClipboardReply = false
            index = end
        }
        while index < bytes.count {
            if bytes[index] == Self.endOfTransmission {
                index += 1
                continue
            }
            guard bytes[index] == Self.escape else {
                isFiltering = false
                output.append(contentsOf: bytes[index...])
                return output
            }

            switch Self.reconnectProbeReplySequence(in: bytes, at: index) {
            case .strip(let length):
                index += length
            case .incomplete:
                let suffix = bytes[index...]
                guard suffix.count <= Self.maxPendingProbeBytes else {
                    isFiltering = false
                    output.append(contentsOf: suffix)
                    return output
                }
                pending.append(contentsOf: suffix)
                return output
            case .passThrough:
                isFiltering = false
                output.append(contentsOf: bytes[index...])
                return output
            case .unterminatedClipboardReply:
                discardingClipboardReply = true
                retainTrailingEscapeOfDiscardedReply(bytes)
                return output
            }
        }

        return output
    }

    /// Keeps a trailing ESC so a string terminator split across reads is seen.
    private mutating func retainTrailingEscapeOfDiscardedReply(_ bytes: [UInt8]) {
        if bytes.last == Self.escape {
            pending.append(Self.escape)
        }
    }

    /// Returns any incomplete escape sequence retained by the filter.
    ///
    /// - Returns: Pending bytes in their original order.
    public mutating func finish() -> Data {
        if discardingClipboardReply {
            // Never forward any part of a clipboard reply.
            discardingClipboardReply = false
            pending.removeAll(keepingCapacity: false)
            return Data()
        }
        guard !pending.isEmpty else {
            return Data()
        }
        let data = Data(pending)
        pending.removeAll(keepingCapacity: false)
        return data
    }

    /// Ends filtering and returns any retained incomplete sequence.
    ///
    /// - Returns: Pending bytes that must be forwarded before live input.
    public mutating func stopFiltering() -> Data {
        let input = finish()
        isFiltering = false
        return input
    }

    /// Whether an incomplete probe reply is buffered awaiting more bytes.
    ///
    /// Callers may end filtering with ``stopFiltering()`` when this stays true
    /// past a short continuation timeout, which forwards the buffered bytes.
    /// A clipboard reply being discarded is deliberately excluded: a pause in
    /// the middle of one must not end filtering, or the rest of the clipboard
    /// would reach the remote PTY. Discarding therefore lasts until BEL/ST
    /// arrives or filtering stops (the caller's reconnect deadline,
    /// ``finish()`` or ``stopFiltering()``), and nothing retained is forwarded.
    /// The trade-off: if the terminator is lost, input typed before that
    /// deadline is discarded with the reply.
    public var hasPendingInput: Bool {
        isFiltering && !pending.isEmpty && !discardingClipboardReply
    }

    /// Whether filtering is active with no partial sequence buffered.
    public var isFilteringAtProbeBoundary: Bool {
        isFiltering && pending.isEmpty && !discardingClipboardReply
    }

    /// Whether recognized reconnect-time replies are still being removed.
    public var isFilteringActive: Bool {
        isFiltering
    }

    private static func reconnectProbeReplySequence(
        in bytes: [UInt8],
        at start: Int
    ) -> SequenceMatch {
        guard start < bytes.count, bytes[start] == escape else {
            return .passThrough
        }
        guard start + 1 < bytes.count else {
            return .incomplete
        }

        switch bytes[start + 1] {
        case rightBracket:
            return oscReplySequence(in: bytes, at: start)
        case leftBracket:
            return csiProbeReplySequence(in: bytes, at: start)
        case dcs:
            return xtversionReplySequence(in: bytes, at: start)
        default:
            return .passThrough
        }
    }

    private static func xtversionReplySequence(
        in bytes: [UInt8],
        at start: Int
    ) -> SequenceMatch {
        // XTVERSION replies are DCS `>|text ST`. The payload is deliberately
        // treated as opaque: only the protocol prefix identifies this reply.
        guard start + 2 < bytes.count else { return .incomplete }
        guard bytes[start + 2] == 0x3E else { return .passThrough }
        guard start + 3 < bytes.count else { return .incomplete }
        guard bytes[start + 3] == 0x7C else { return .passThrough }
        var cursor = start + 4
        while cursor < bytes.count {
            if bytes[cursor] == escape {
                guard cursor + 1 < bytes.count else { return .incomplete }
                if bytes[cursor + 1] == backslash {
                    return .strip(length: cursor - start + 2)
                }
            }
            cursor += 1
        }
        return .incomplete
    }

    private static func oscReplySequence(
        in bytes: [UInt8],
        at start: Int
    ) -> SequenceMatch {
        var cursor = start + 2
        var command = [UInt8]()

        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == semicolon {
                break
            }
            if byte < 0x30 || byte > 0x39 || command.count >= 2 {
                return .passThrough
            }
            command.append(byte)
            cursor += 1
        }

        guard cursor < bytes.count else {
            return isOSCReplyCommandPrefix(command) ? .incomplete : .passThrough
        }
        guard bytes[cursor] == semicolon else {
            return .passThrough
        }
        let isClipboardReply = command == [0x35, 0x32]
        guard isClipboardReply ||
            command == [0x31, 0x30] || command == [0x31, 0x31] || command == [0x31, 0x32] else {
            return .passThrough
        }

        guard let end = stringTerminatorEnd(in: bytes, from: cursor + 1) else {
            return isClipboardReply ? .unterminatedClipboardReply : .incomplete
        }
        return .strip(length: end - start)
    }

    /// Returns the index just past the first BEL or ST at or after `start`.
    private static func stringTerminatorEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == bell {
                return cursor + 1
            }
            if byte == escape, cursor + 1 < bytes.count, bytes[cursor + 1] == backslash {
                return cursor + 2
            }
            cursor += 1
        }
        return nil
    }

    private static func csiProbeReplySequence(
        in bytes: [UInt8],
        at start: Int
    ) -> SequenceMatch {
        var cursor = start + 2
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte >= 0x40, byte <= 0x7E {
                return shouldStripCSIReply(bytes: bytes, bodyStart: start + 2, finalIndex: cursor)
                    ? .strip(length: cursor - start + 1)
                    : .passThrough
            }
            guard byte >= 0x20, byte <= 0x3F else {
                return .passThrough
            }
            cursor += 1
        }
        return .incomplete
    }

    private static func isOSCReplyCommandPrefix(_ command: [UInt8]) -> Bool {
        command.isEmpty ||
            command == [0x35] ||
            command == [0x35, 0x32] ||
            command == [0x31] ||
            command == [0x31, 0x30] ||
            command == [0x31, 0x31] ||
            command == [0x31, 0x32]
    }

    private static func shouldStripCSIReply(bytes: [UInt8], bodyStart: Int, finalIndex: Int) -> Bool {
        var parameterEnd = bodyStart
        while parameterEnd < finalIndex, bytes[parameterEnd] >= 0x30, bytes[parameterEnd] <= 0x3F {
            parameterEnd += 1
        }
        guard bytes[parameterEnd..<finalIndex].allSatisfy({ $0 >= 0x20 && $0 <= 0x2F }) else {
            return false
        }

        let parameters = bytes[bodyStart..<parameterEnd]
        let intermediates = bytes[parameterEnd..<finalIndex]
        let final = bytes[finalIndex]

        switch final {
        case 0x49, 0x4F:
            return parameters.isEmpty && intermediates.isEmpty
        case 0x52, 0x63, 0x6E:
            return intermediates.isEmpty
        case 0x75:
            return intermediates.isEmpty && parameters.first == questionMark
        case 0x79:
            return intermediates.elementsEqual([dollar])
        default:
            return false
        }
    }
}
