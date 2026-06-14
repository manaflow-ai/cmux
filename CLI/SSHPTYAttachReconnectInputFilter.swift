import Darwin
import Foundation

final class SSHPTYAttachReconnectInputFilter {
    private static let escape: UInt8 = 0x1B
    private static let bell: UInt8 = 0x07
    private static let leftBracket: UInt8 = 0x5B
    private static let rightBracket: UInt8 = 0x5D
    private static let backslash: UInt8 = 0x5C
    private static let semicolon: UInt8 = 0x3B
    private static let questionMark: UInt8 = 0x3F
    private static let dollar: UInt8 = 0x24
    private static let maxPendingProbeBytes = 512
    // Terminal reconnect drain: enough for split queued replies, bounded for live input.
    private static let initialProbeDrainTimeoutMilliseconds: Int32 = 25

    private var isFiltering: Bool
    private var pending = [UInt8]()

    init(enabled: Bool) {
        isFiltering = enabled
    }

    static func startStdinPump(fd: Int32, filterEnabled: Bool) throws {
        if filterEnabled {
            // Must complete before bridge output is relayed; after that, probe replies are live input.
            try drainQueuedProbeReplies(fd: fd)
        }
        DispatchQueue.global(qos: .userInteractive).async {
            pumpStdin(fd: fd)
        }
    }

    private static func drainQueuedProbeReplies(fd: Int32) throws {
        let reconnectInputFilter = SSHPTYAttachReconnectInputFilter(enabled: true)
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            guard stdinHasReadyInput(timeoutMilliseconds: initialProbeDrainTimeoutMilliseconds) else {
                let input = reconnectInputFilter.flushPendingInput()
                if !input.isEmpty {
                    try writeAll(fd: fd, data: input)
                }
                reconnectInputFilter.stopFilteringAtProbeBoundary()
                return
            }

            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 {
                let input = reconnectInputFilter.filter(Data(buffer.prefix(count)))
                if !input.isEmpty {
                    try writeAll(fd: fd, data: input)
                }
                if !reconnectInputFilter.hasPendingInput,
                   !reconnectInputFilter.isFilteringAtProbeBoundary {
                    return
                }
            } else if count == 0 {
                let input = reconnectInputFilter.finish()
                if !input.isEmpty {
                    try writeAll(fd: fd, data: input)
                }
                _ = shutdown(fd, SHUT_WR)
                return
            } else if errno != EINTR {
                _ = shutdown(fd, SHUT_WR)
                return
            }
        }
    }

    private static func pumpStdin(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 {
                let input = Data(buffer.prefix(count))
                do {
                    try Self.writeAll(fd: fd, data: input)
                } catch {
                    _ = shutdown(fd, SHUT_WR)
                    return
                }
            } else if count == 0 {
                _ = shutdown(fd, SHUT_WR)
                return
            } else if errno != EINTR {
                _ = shutdown(fd, SHUT_WR)
                return
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

    var hasPendingInput: Bool {
        isFiltering && !pending.isEmpty
    }

    var isFilteringAtProbeBoundary: Bool {
        isFiltering && pending.isEmpty
    }

    func flushPendingInput() -> Data {
        guard hasPendingInput else {
            return Data()
        }
        let data = Data(pending)
        pending.removeAll(keepingCapacity: true)
        isFiltering = false
        return data
    }

    func stopFilteringAtProbeBoundary() {
        guard isFilteringAtProbeBoundary else {
            return
        }
        isFiltering = false
    }

    private static func reconnectProbeReplySequence(
        in bytes: [UInt8],
        at start: Int
    ) -> SSHPTYAttachReconnectInputFilterSequenceMatch {
        guard start < bytes.count, bytes[start] == escape else {
            return .passThrough
        }
        guard start + 1 < bytes.count else {
            // read() can split immediately after ESC; wait for one more byte before deciding.
            return .incomplete
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

    private static func oscColorReplySequence(
        in bytes: [UInt8],
        at start: Int
    ) -> SSHPTYAttachReconnectInputFilterSequenceMatch {
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
            return isOSCColorReplyCommandPrefix(command) ? .incomplete : .passThrough
        }
        guard bytes[cursor] == semicolon else {
            return .passThrough
        }
        guard command == [0x31, 0x30] || command == [0x31, 0x31] || command == [0x31, 0x32] else {
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
        return .incomplete
    }

    private static func csiProbeReplySequence(
        in bytes: [UInt8],
        at start: Int
    ) -> SSHPTYAttachReconnectInputFilterSequenceMatch {
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

    private static func isOSCColorReplyCommandPrefix(_ command: [UInt8]) -> Bool {
        command.isEmpty ||
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

    private static func stdinHasReadyInput(timeoutMilliseconds: Int32) -> Bool {
        var stdinPoll = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while true {
            let result = Darwin.poll(&stdinPoll, 1, timeoutMilliseconds)
            if result > 0 {
                return (stdinPoll.revents & Int16(POLLIN)) != 0
            }
            if result == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
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
                    throw POSIXError(.EIO)
                }
            }
        }
    }
}
