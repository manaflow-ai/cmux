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
    // Terminal ESC disambiguation: bounded so a literal Escape key is not held indefinitely.
    private static let pendingProbeContinuationTimeoutMilliseconds: Int32 = 25
    private static let reconnectProbeDeadlineMilliseconds: Int64 = 2_000

    private var isFiltering: Bool
    private var pending = [UInt8]()
    private let deadlineReached: (@Sendable () -> Bool)?
    private let remainingDeadline: (@Sendable () -> Int64?)?

    init(
        enabled: Bool,
        deadlineReached: (@Sendable () -> Bool)? = nil,
        remainingDeadlineMilliseconds: (@Sendable () -> Int64?)? = nil
    ) {
        isFiltering = enabled
        self.deadlineReached = deadlineReached
        remainingDeadline = remainingDeadlineMilliseconds
    }

    private init(state: SSHPTYAttachReconnectInputFilterState) {
        isFiltering = state.isFiltering
        pending = state.pending
        deadlineReached = state.deadlineReached
        remainingDeadline = state.remainingDeadlineMilliseconds
    }

    @discardableResult
    static func startStdinPump(
        fd: Int32,
        inputFD: Int32 = STDIN_FILENO,
        filterEnabled: Bool,
        monotonicNowMilliseconds: (@Sendable () -> Int64)? = nil,
        beforeForwardingInput: (@Sendable () async -> Void)? = nil
    ) throws -> SSHPTYAttachReconnectInputFilterControl? {
        let now = monotonicNowMilliseconds ?? {
            Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        }
        let deadline = filterEnabled ? now() + reconnectProbeDeadlineMilliseconds : nil
        let filterState = filterEnabled
            ? SSHPTYAttachReconnectInputFilterState(
                isFiltering: true,
                pending: [],
                deadlineReached: { deadline.map { now() >= $0 } ?? false },
                remainingDeadlineMilliseconds: {
                    guard let deadline else { return nil }
                    return max(0, deadline - now())
                }
            )
            : nil
        var stopSignalFDs = [Int32](repeating: -1, count: 2)
        let filterControl: SSHPTYAttachReconnectInputFilterControl?
        let stopSignalReadFD: Int32?
        let stopAcknowledgementWriteFD: Int32?
        if !filterEnabled {
            filterControl = nil
            stopSignalReadFD = nil
            stopAcknowledgementWriteFD = nil
        } else {
            guard Darwin.pipe(&stopSignalFDs) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var stopAcknowledgementFDs = [Int32](repeating: -1, count: 2)
            guard Darwin.pipe(&stopAcknowledgementFDs) == 0 else {
                Darwin.close(stopSignalFDs[0])
                Darwin.close(stopSignalFDs[1])
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Read ends can close mid-write: writers get EPIPE, never SIGPIPE.
            _ = fcntl(stopSignalFDs[1], F_SETNOSIGPIPE, 1)
            _ = fcntl(stopAcknowledgementFDs[1], F_SETNOSIGPIPE, 1)
            filterControl = SSHPTYAttachReconnectInputFilterControl(
                stopSignalWriteFD: stopSignalFDs[1],
                stopAcknowledgementReadFD: stopAcknowledgementFDs[0]
            )
            stopSignalReadFD = stopSignalFDs[0]
            stopAcknowledgementWriteFD = stopAcknowledgementFDs[1]
        }
        Task.detached(priority: .userInitiated) {
            await Self.pumpStdin(
                inputFD: inputFD,
                fd: fd,
                reconnectInputFilterState: filterState,
                retainedFilterControl: filterControl,
                stopSignalFD: stopSignalReadFD,
                stopAcknowledgementFD: stopAcknowledgementWriteFD,
                beforeForwardingInput: beforeForwardingInput
            )
        }
        return filterControl
    }

    private static func pumpStdin(
        inputFD: Int32,
        fd: Int32,
        reconnectInputFilterState: SSHPTYAttachReconnectInputFilterState?,
        retainedFilterControl: SSHPTYAttachReconnectInputFilterControl?,
        stopSignalFD initialStopSignalFD: Int32?,
        stopAcknowledgementFD initialStopAcknowledgementFD: Int32?,
        beforeForwardingInput: (@Sendable () async -> Void)?
    ) async {
        _ = retainedFilterControl
        var reconnectInputFilter = reconnectInputFilterState.map(SSHPTYAttachReconnectInputFilter.init(state:))
        var stopSignalFD = initialStopSignalFD
        var stopAcknowledgementFD = initialStopAcknowledgementFD
        var buffer = [UInt8](repeating: 0, count: 8192)
        defer {
            if let stopSignalFD {
                Darwin.close(stopSignalFD)
            }
            if let stopAcknowledgementFD {
                Darwin.close(stopAcknowledgementFD)
            }
        }

        func writeOrShutdown(_ input: Data) async -> Bool {
            guard !input.isEmpty else {
                return true
            }
            if let beforeForwardingInput {
                await beforeForwardingInput()
            }
            do {
                try Self.writeAll(fd: fd, data: input)
                return true
            } catch {
                _ = shutdown(fd, SHUT_WR)
                return false
            }
        }

        func acknowledgeStopFiltering() {
            guard let fd = stopAcknowledgementFD else {
                return
            }
            var byte: UInt8 = 1
            while true {
                let written = withUnsafePointer(to: &byte) { pointer in
                    Darwin.write(fd, pointer, 1)
                }
                if written > 0 || errno != EINTR {
                    Darwin.close(fd)
                    stopAcknowledgementFD = nil
                    return
                }
            }
        }

        func closeStopSignal() {
            guard let fd = stopSignalFD else {
                return
            }
            Darwin.close(fd)
            stopSignalFD = nil
        }

        func finishReconnectFilteringWithoutFlush() {
            reconnectInputFilter = nil
            acknowledgeStopFiltering()
        }

        func stopReconnectFiltering() -> Bool {
            defer {
                acknowledgeStopFiltering()
                closeStopSignal()
            }
            reconnectInputFilter = nil
            return true
        }

        func flushPendingThenShutdown() async {
            if let filter = reconnectInputFilter, filter.hasPendingInput {
                _ = await writeOrShutdown(filter.flushPendingInput())
            }
            _ = shutdown(fd, SHUT_WR)
        }

        func stopReconnectFilteringAtDeadline() async -> Bool {
            guard let filter = reconnectInputFilter else { return true }
            guard await writeOrShutdown(filter.stopFiltering()) else { return false }
            return stopReconnectFiltering()
        }

        while true {
            if reconnectInputFilter?.isDeadlineReached == true {
                guard await stopReconnectFilteringAtDeadline() else { return }
                continue
            }
            var timeoutMilliseconds = reconnectInputFilter?.hasPendingInput == true
                ? pendingProbeContinuationTimeoutMilliseconds
                : -1
            if let remaining = reconnectInputFilter?.remainingDeadlineMilliseconds {
                let capped = Int32(min(Int64(Int32.max), remaining))
                timeoutMilliseconds = timeoutMilliseconds < 0 ? capped : min(timeoutMilliseconds, capped)
            }
            guard var readiness = pollStdinPump(
                inputFD: inputFD,
                stopSignalFD: stopSignalFD,
                timeoutMilliseconds: timeoutMilliseconds
            ) else {
                await flushPendingThenShutdown()
                return
            }

            if readiness.stopRequested,
               !readiness.inputReady,
               reconnectInputFilter?.hasPendingInput == true {
                guard let pendingReadiness = pollStdinPump(
                    inputFD: inputFD,
                    stopSignalFD: nil,
                    timeoutMilliseconds: pendingProbeContinuationTimeoutMilliseconds
                ) else {
                    await flushPendingThenShutdown()
                    return
                }
                if pendingReadiness.inputReady {
                    readiness = (inputReady: true, stopRequested: true)
                } else if let filter = reconnectInputFilter {
                    guard await writeOrShutdown(filter.flushPendingInput()) else { return }
                    guard stopReconnectFiltering() else { return }
                    continue
                }
            }

            if readiness.stopRequested, !readiness.inputReady {
                guard stopReconnectFiltering() else {
                    return
                }
                continue
            }

            if !readiness.inputReady {
                if let filter = reconnectInputFilter,
                   filter.hasPendingInput {
                    guard await writeOrShutdown(filter.flushPendingInput()) else { return }
                }
                continue
            }

            let count = Darwin.read(inputFD, &buffer, buffer.count)
            if count > 0 {
                let rawInput = Data(buffer.prefix(count))
                let input: Data
                if let filter = reconnectInputFilter {
                    input = filter.filter(rawInput)
                    if !filter.isFilteringActive {
                        finishReconnectFilteringWithoutFlush()
                    }
                } else {
                    input = rawInput
                }
                guard await writeOrShutdown(input) else {
                    return
                }
                if readiness.stopRequested {
                    if reconnectInputFilter?.hasPendingInput == true {
                        continue
                    }
                    guard stopReconnectFiltering() else {
                        return
                    }
                }
            } else if count == 0 {
                await flushPendingThenShutdown()
                return
            } else if errno != EINTR {
                await flushPendingThenShutdown()
                return
            }
        }
    }

    func filter(_ data: Data) -> Data {
        guard isFiltering, !data.isEmpty else {
            return data
        }
        if isDeadlineReached {
            var output = stopFiltering()
            output.append(data)
            return output
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

    func stopFiltering() -> Data {
        let input = finish()
        isFiltering = false
        return input
    }

    var hasPendingInput: Bool {
        isFiltering && !pending.isEmpty
    }

    var isFilteringAtProbeBoundary: Bool {
        isFiltering && pending.isEmpty
    }

    var isFilteringActive: Bool {
        isFiltering
    }

    var isDeadlineReached: Bool {
        isFiltering && (deadlineReached?() == true)
    }

    var remainingDeadlineMilliseconds: Int64? {
        guard isFiltering else { return nil }
        return remainingDeadline?()
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

}
