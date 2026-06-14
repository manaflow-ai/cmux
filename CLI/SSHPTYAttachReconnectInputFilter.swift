import Darwin
import Foundation

final class SSHPTYAttachReconnectInputFilter {
    private enum SequenceMatch {
        case strip(length: Int)
        case incomplete
        case passThrough
    }

    private static let escape: UInt8 = 0x1B
    private static let bell: UInt8 = 0x07
    private static let leftBracket: UInt8 = 0x5B
    private static let rightBracket: UInt8 = 0x5D
    private static let backslash: UInt8 = 0x5C
    private static let semicolon: UInt8 = 0x3B
    private static let questionMark: UInt8 = 0x3F
    private static let dollar: UInt8 = 0x24
    private static let maxPendingProbeBytes = 512

    private var isFiltering: Bool
    private var pending = [UInt8]()

    init(enabled: Bool) {
        isFiltering = enabled
    }

    static func startStdinPump(fd: Int32, filterEnabled: Bool) {
        DispatchQueue.global(qos: .userInteractive).async {
            let reconnectInputFilter = SSHPTYAttachReconnectInputFilter(enabled: filterEnabled)
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 {
                    let input = reconnectInputFilter.filter(Data(buffer.prefix(count)))
                    guard !input.isEmpty else {
                        continue
                    }
                    do {
                        try Self.writeAll(fd: fd, data: input)
                    } catch {
                        _ = shutdown(fd, SHUT_WR)
                        return
                    }
                } else if count == 0 {
                    let input = reconnectInputFilter.finish()
                    if !input.isEmpty {
                        do {
                            try Self.writeAll(fd: fd, data: input)
                        } catch {
                            _ = shutdown(fd, SHUT_WR)
                            return
                        }
                    }
                    _ = shutdown(fd, SHUT_WR)
                    return
                } else if errno != EINTR {
                    _ = shutdown(fd, SHUT_WR)
                    return
                }
            }
        }
    }

    func filter(_ data: Data) -> Data {
        guard isFiltering, !data.isEmpty else {
            return data
        }

        var bytes = pending
        pending.removeAll(keepingCapacity: true)
        bytes.append(contentsOf: data)

        var output = Data()
        var index = 0
        while index < bytes.count {
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
            }
        }

        return output
    }

    func finish() -> Data {
        guard !pending.isEmpty else {
            return Data()
        }
        let data = Data(pending)
        pending.removeAll(keepingCapacity: false)
        return data
    }

    private static func reconnectProbeReplySequence(in bytes: [UInt8], at start: Int) -> SequenceMatch {
        guard start < bytes.count, bytes[start] == escape else {
            return .passThrough
        }
        guard start + 1 < bytes.count else {
            return .passThrough
        }

        switch bytes[start + 1] {
        case rightBracket:
            return oscColorReplySequence(in: bytes, at: start)
        case leftBracket:
            return csiProbeReplySequence(in: bytes, at: start)
        default:
            return .passThrough
        }
    }

    private static func oscColorReplySequence(in bytes: [UInt8], at start: Int) -> SequenceMatch {
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
            return .passThrough
        }
        guard bytes[cursor] == semicolon else {
            return .passThrough
        }
        guard command == [0x31, 0x30] || command == [0x31, 0x31] else {
            return .passThrough
        }

        cursor += 1
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == bell {
                return .strip(length: cursor - start + 1)
            }
            if byte == escape {
                guard cursor + 1 < bytes.count else {
                    return .incomplete
                }
                if bytes[cursor + 1] == backslash {
                    return .strip(length: cursor - start + 2)
                }
            }
            cursor += 1
        }
        return .passThrough
    }

    private static func csiProbeReplySequence(in bytes: [UInt8], at start: Int) -> SequenceMatch {
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

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw CLIError(message: "ssh-pty-attach: bridge write failed")
                }
            }
        }
    }
}
