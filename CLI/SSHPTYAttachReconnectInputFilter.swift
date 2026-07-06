import Darwin
import Foundation

struct SSHPTYAttachReconnectInputFilterState: Sendable {
    let isFiltering: Bool
    let pending: [UInt8]
}

final class SSHPTYAttachReconnectInputFilterControl: Sendable {
    private let stopSignalWriteFD: Int32
    private let stopAcknowledgementReadFD: Int32

    init(stopSignalWriteFD: Int32, stopAcknowledgementReadFD: Int32) {
        self.stopSignalWriteFD = stopSignalWriteFD
        self.stopAcknowledgementReadFD = stopAcknowledgementReadFD
    }

    deinit {
        Darwin.close(stopSignalWriteFD)
        Darwin.close(stopAcknowledgementReadFD)
    }

    @discardableResult
    func stopFiltering(timeoutMilliseconds: Int32? = nil) -> Bool {
        if stopAcknowledgementReady() {
            return waitForStopAcknowledgement(timeoutMilliseconds: timeoutMilliseconds)
        }
        signalStopFiltering()
        return waitForStopAcknowledgement(timeoutMilliseconds: timeoutMilliseconds)
    }

    func stopFilteringBeforeFirstOutput(unlessAlreadyRequested alreadyRequested: inout Bool) {
        guard !alreadyRequested else {
            return
        }
        stopFiltering(timeoutMilliseconds: 250)
        alreadyRequested = true
    }

    private func stopAcknowledgementReady() -> Bool {
        let events = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        var pollFD = pollfd(fd: stopAcknowledgementReadFD, events: events, revents: 0)
        while true {
            let result = Darwin.poll(&pollFD, 1, 0)
            if result > 0 {
                return (pollFD.revents & events) != 0
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                return true
            }
        }
    }

    private func signalStopFiltering() {
        var byte: UInt8 = 1
        while true {
            let written = withUnsafePointer(to: &byte) { pointer in
                Darwin.write(stopSignalWriteFD, pointer, 1)
            }
            if written > 0 || errno != EINTR {
                return
            }
        }
    }

    private func waitForStopAcknowledgement(timeoutMilliseconds: Int32?) -> Bool {
        if let timeoutMilliseconds,
           !stopAcknowledgementReady(timeoutMilliseconds: timeoutMilliseconds) {
            return false
        }
        var byte: UInt8 = 0
        while true {
            let count = withUnsafeMutablePointer(to: &byte) { pointer in
                Darwin.read(stopAcknowledgementReadFD, pointer, 1)
            }
            if count > 0 || count == 0 || errno != EINTR {
                return true
            }
        }
    }

    private func stopAcknowledgementReady(timeoutMilliseconds: Int32) -> Bool {
        let events = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        var pollFD = pollfd(fd: stopAcknowledgementReadFD, events: events, revents: 0)
        while true {
            let result = Darwin.poll(&pollFD, 1, timeoutMilliseconds)
            if result > 0 {
                return (pollFD.revents & events) != 0
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                return true
            }
        }
    }
}

enum SSHPTYAttachReconnectInputFilterSequenceMatch {
    case strip(length: Int)
    case incomplete
    case passThrough
}

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

    private var isFiltering: Bool
    private var pending = [UInt8]()

    init(enabled: Bool) {
        isFiltering = enabled
    }

    private init(state: SSHPTYAttachReconnectInputFilterState) {
        isFiltering = state.isFiltering
        pending = state.pending
    }

    @discardableResult
    static func startStdinPump(
        fd: Int32,
        inputFD: Int32 = STDIN_FILENO,
        filterEnabled: Bool,
        beforeForwardingInput: (@Sendable () async -> Void)? = nil
    ) throws -> SSHPTYAttachReconnectInputFilterControl? {
        let filterState = filterEnabled
            ? SSHPTYAttachReconnectInputFilterState(isFiltering: true, pending: [])
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

        while true {
            let timeoutMilliseconds = reconnectInputFilter?.hasPendingInput == true
                ? pendingProbeContinuationTimeoutMilliseconds
                : -1
            guard var readiness = pollStdinPump(
                inputFD: inputFD,
                stopSignalFD: stopSignalFD,
                timeoutMilliseconds: timeoutMilliseconds
            ) else {
                _ = shutdown(fd, SHUT_WR)
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
                    _ = shutdown(fd, SHUT_WR)
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

    private static func pollStdinPump(
        inputFD: Int32,
        stopSignalFD: Int32?,
        timeoutMilliseconds: Int32
    ) -> (inputReady: Bool, stopRequested: Bool)? {
        let inputEvents = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        let stopEvents = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        var pollFDs = [pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)]
        if let stopSignalFD {
            pollFDs.append(pollfd(fd: stopSignalFD, events: Int16(POLLIN), revents: 0))
        }

        while true {
            let result = pollFDs.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), timeoutMilliseconds)
            }
            if result > 0 {
                let inputReady = (pollFDs[0].revents & inputEvents) != 0
                let stopRequested = pollFDs.count > 1 && (pollFDs[1].revents & stopEvents) != 0
                return (inputReady: inputReady, stopRequested: stopRequested)
            }
            if result == 0 {
                return (inputReady: false, stopRequested: false)
            }
            if errno == EINTR {
                continue
            }
            return nil
        }
    }
}
