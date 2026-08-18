public import Foundation

/// Removes terminal query requests from the initial replay of a persistent SSH PTY.
///
/// The remote PTY owns the captured scrollback. Replaying a query into the local
/// terminal emulator would make the emulator answer it against the live shell,
/// so only the declared replay prefix is inspected. Bytes after that boundary
/// are forwarded byte-for-byte and live terminal negotiation remains unchanged.
public struct SSHPTYReplayOutputFilter: Sendable {
    private static let escape: UInt8 = 0x1B
    private static let enquiry: UInt8 = 0x05
    private static let leftBracket: UInt8 = 0x5B
    private static let rightBracket: UInt8 = 0x5D
    private static let dcs: UInt8 = 0x50
    private static let apc: UInt8 = 0x5F
    private static let bell: UInt8 = 0x07
    private static let backslash: UInt8 = 0x5C
    private static let semicolon: UInt8 = 0x3B
    private static let maxPendingBytes = 4 * 1024

    private enum SequenceMatch {
        case strip(length: Int)
        case incomplete
        case passThrough
    }

    private var replayBytesRemaining: Int
    private var pending = [UInt8]()

    /// Creates a filter for one ordered PTY attachment output stream.
    ///
    /// - Parameter replayBytes: Number of leading output bytes belonging to
    ///   the daemon's scrollback replay. Negative values are treated as zero.
    public init(replayBytes: Int) {
        replayBytesRemaining = max(0, replayBytes)
    }

    /// Filters one output chunk, stripping only query sequences that begin in replay.
    ///
    /// A candidate may span output chunks and the replay/live boundary. The
    /// candidate stays bounded; malformed or oversized input fails open so
    /// visible output is not lost.
    ///
    /// - Parameter data: Ordered bytes received from the PTY bridge.
    /// - Returns: Bytes safe to deliver to the local terminal emulator.
    public mutating func filter(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        guard replayBytesRemaining > 0 || !pending.isEmpty else { return data }

        var bytes = pending
        pending.removeAll(keepingCapacity: true)
        bytes.append(contentsOf: data)

        var output = Data()
        var index = 0
        let replayBytesInBuffer = min(replayBytesRemaining, bytes.count)
        while index < bytes.count {
            let startsInReplay = index < replayBytesInBuffer
            if bytes[index] == Self.enquiry, startsInReplay {
                index += 1
                replayBytesRemaining -= 1
                continue
            }

            guard bytes[index] == Self.escape else {
                output.append(bytes[index])
                if startsInReplay { replayBytesRemaining -= 1 }
                index += 1
                continue
            }

            switch Self.querySequence(in: bytes, at: index) {
            case .strip(let length) where startsInReplay:
                index += length
                replayBytesRemaining -= min(length, replayBytesRemaining)
            case .incomplete where startsInReplay:
                let suffix = bytes[index...]
                guard suffix.count <= Self.maxPendingBytes else {
                    output.append(contentsOf: suffix)
                    replayBytesRemaining -= min(suffix.count, replayBytesRemaining)
                    return output
                }
                pending.append(contentsOf: suffix)
                return output
            case .passThrough, .strip(_):
                output.append(bytes[index])
                if startsInReplay { replayBytesRemaining -= 1 }
                index += 1
            case .incomplete:
                output.append(contentsOf: bytes[index...])
                return output
            }
        }
        return output
    }

    /// Flushes an unterminated candidate when the bridge closes.
    ///
    /// Unterminated bytes cannot produce a terminal response, so they are
    /// returned unchanged to preserve the replay artifact.
    public mutating func finish() -> Data {
        guard !pending.isEmpty else { return Data() }
        let value = Data(pending)
        pending.removeAll(keepingCapacity: false)
        replayBytesRemaining = max(0, replayBytesRemaining - value.count)
        return value
    }

    /// Number of replay bytes not yet consumed by the filter.
    public var remainingReplayBytes: Int { replayBytesRemaining }

    private static func querySequence(in bytes: [UInt8], at start: Int) -> SequenceMatch {
        guard start < bytes.count, bytes[start] == Self.escape else {
            return .passThrough
        }
        guard start + 1 < bytes.count else { return .incomplete }
        switch bytes[start + 1] {
        case Self.leftBracket:
            return csiQuery(in: bytes, at: start)
        case Self.rightBracket:
            return oscQuery(in: bytes, at: start)
        case Self.dcs:
            return dcsQuery(in: bytes, at: start)
        case Self.apc:
            return apcQuery(in: bytes, at: start)
        case 0x5A: // DECID (ESC Z)
            return .strip(length: 2)
        default:
            return .passThrough
        }
    }

    private static func csiQuery(in bytes: [UInt8], at start: Int) -> SequenceMatch {
        var cursor = start + 2
        var intermediates = [UInt8]()
        var parameters = [UInt8]()
        var sawParameter = false

        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte >= 0x40, byte <= 0x7E {
                return isCSIQuery(
                    parameters: parameters,
                    intermediates: intermediates,
                    final: byte,
                    sawParameter: sawParameter
                )
                    ? .strip(length: cursor - start + 1)
                    : .passThrough
            }
            if byte >= 0x30, byte <= 0x3B {
                parameters.append(byte)
                sawParameter = true
                cursor += 1
                continue
            }
            if (byte >= 0x20 && byte <= 0x2F) || (byte >= 0x3C && byte <= 0x3F) {
                intermediates.append(byte)
                cursor += 1
                continue
            }
            return .passThrough
        }
        return .incomplete
    }

    private static func isCSIQuery(
        parameters: [UInt8],
        intermediates: [UInt8],
        final: UInt8,
        sawParameter: Bool
    ) -> Bool {
        switch final {
        case 0x63: // DA1/DA2/DA3
            return intermediates.isEmpty || intermediates == [0x3E] || intermediates == [0x3D]
        case 0x6E: // DSR
            return (intermediates.isEmpty || intermediates == [0x3F]) && sawSingleNumericParameter(parameters)
        case 0x70: // DECRQM / DECRQM-ANSI
            return (intermediates == [0x24] || intermediates == [0x3F, 0x24]) &&
                sawSingleNumericParameter(parameters)
        case 0x71: // XTVERSION (CSI > q)
            return intermediates == [0x3E] && !sawParameter
        case 0x74: // XTWINOPS size queries
            return intermediates.isEmpty && [
                Array("14".utf8), Array("16".utf8), Array("18".utf8), Array("21".utf8),
            ].contains(parameters)
        case 0x75: // Kitty keyboard query (CSI ? u)
            return intermediates == [0x3F] && !sawParameter
        default:
            return false
        }
    }

    private static func sawSingleNumericParameter(_ parameters: [UInt8]) -> Bool {
        !parameters.isEmpty && parameters.allSatisfy { byte in
            byte >= 0x30 && byte <= 0x39
        }
    }

    private static func oscQuery(in bytes: [UInt8], at start: Int) -> SequenceMatch {
        var cursor = start + 2
        var command = [UInt8]()
        while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            command.append(bytes[cursor])
            cursor += 1
        }
        guard cursor < bytes.count, bytes[cursor] == Self.semicolon else {
            return cursor == bytes.count ? .incomplete : .passThrough
        }
        cursor += 1
        let payloadStart = cursor
        while cursor < bytes.count {
            if bytes[cursor] == Self.bell {
                return isColorQuery(command: command, payload: Array(bytes[payloadStart..<cursor]))
                    ? .strip(length: cursor - start + 1)
                    : .passThrough
            }
            if bytes[cursor] == Self.escape, cursor + 1 < bytes.count,
               bytes[cursor + 1] == Self.backslash {
                return isColorQuery(command: command, payload: Array(bytes[payloadStart..<cursor]))
                    ? .strip(length: cursor - start + 2)
                    : .passThrough
            }
            cursor += 1
        }
        return .incomplete
    }

    private static func isColorQuery(command: [UInt8], payload: [UInt8]) -> Bool {
        guard command == [0x34] || command == [0x31, 0x30] ||
            command == [0x31, 0x31] || command == [0x31, 0x32] else {
            return false
        }
        return payload.first == 0x3F
    }

    private static func dcsQuery(in bytes: [UInt8], at start: Int) -> SequenceMatch {
        let payloadStart = start + 2
        guard payloadStart < bytes.count else { return .incomplete }
        var cursor = payloadStart
        while cursor < bytes.count {
            if bytes[cursor] == Self.escape, cursor + 1 < bytes.count,
               bytes[cursor + 1] == Self.backslash {
                let payload = bytes[payloadStart..<cursor]
                let isQuery = payload.starts(with: [0x2B, 0x71]) ||
                    payload.starts(with: [0x24, 0x71])
                return isQuery ? .strip(length: cursor - start + 2) : .passThrough
            }
            cursor += 1
        }
        return .incomplete
    }

    private static func apcQuery(in bytes: [UInt8], at start: Int) -> SequenceMatch {
        let payloadStart = start + 2
        guard payloadStart < bytes.count else { return .incomplete }
        var cursor = payloadStart
        while cursor < bytes.count {
            if bytes[cursor] == Self.escape, cursor + 1 < bytes.count,
               bytes[cursor + 1] == Self.backslash {
                let payload = bytes[payloadStart..<cursor]
                // Kitty graphics query commands use `a=q`; leave image and
                // drawing commands intact so replayed visuals are preserved.
                let isQuery = payload.starts(with: [0x47]) && containsSubsequence(
                    payload,
                    [0x61, 0x3D, 0x71]
                )
                return isQuery ? .strip(length: cursor - start + 2) : .passThrough
            }
            cursor += 1
        }
        return .incomplete
    }

    private static func containsSubsequence(_ value: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= value.count else { return false }
        var index = value.startIndex
        while index < value.endIndex {
            guard let end = value.index(index, offsetBy: needle.count, limitedBy: value.endIndex),
                  end <= value.endIndex else {
                return false
            }
            if Array(value[index..<end]) == needle { return true }
            index = value.index(after: index)
        }
        return false
    }
}
