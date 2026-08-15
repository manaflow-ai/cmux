import CmuxFoundation
import Darwin
import Foundation

final class SSHPTYAttachReconnectInputFilter {
    // Terminal ESC disambiguation: bounded so a literal Escape key is not held indefinitely.
    private static let pendingProbeContinuationTimeoutMilliseconds: Int32 = 25
    private static let reconnectProbeDeadlineMilliseconds: Int64 = 2_000

    private var byteFilter: SSHPTYReconnectInputByteFilter
    private let deadlineReached: (@Sendable () -> Bool)?
    private let remainingDeadline: (@Sendable () -> Int64?)?

    init(
        enabled: Bool,
        deadlineReached: (@Sendable () -> Bool)? = nil,
        remainingDeadlineMilliseconds: (@Sendable () -> Int64?)? = nil
    ) {
        byteFilter = SSHPTYReconnectInputByteFilter(enabled: enabled)
        self.deadlineReached = deadlineReached
        remainingDeadline = remainingDeadlineMilliseconds
    }

    private init(state: SSHPTYAttachReconnectInputFilterState) {
        byteFilter = SSHPTYReconnectInputByteFilter(enabled: state.isFiltering)
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

        func finishStdin() {
            // Reconnect input can disappear with the old bridge during wake.
            // It is not an intentional EOF for the newly attached remote PTY.
            guard reconnectInputFilter == nil else { return }
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
                finishStdin()
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
                    finishStdin()
                    return
                }
                if pendingReadiness.inputReady {
                    readiness = (inputReady: true, stopRequested: true)
                } else if let filter = reconnectInputFilter {
                    guard await writeOrShutdown(filter.stopFiltering()) else { return }
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
                    guard await writeOrShutdown(filter.stopFiltering()) else { return }
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
                finishStdin()
                return
            } else if errno != EINTR {
                finishStdin()
                return
            }
        }
    }

    func filter(_ data: Data) -> Data {
        if isDeadlineReached {
            var output = stopFiltering()
            output.append(data)
            return output
        }
        return byteFilter.filter(data)
    }

    func finish() -> Data {
        byteFilter.finish()
    }

    func stopFiltering() -> Data {
        byteFilter.stopFiltering()
    }

    var hasPendingInput: Bool {
        byteFilter.hasPendingInput
    }

    var isFilteringAtProbeBoundary: Bool {
        byteFilter.isFilteringAtProbeBoundary
    }

    var isFilteringActive: Bool {
        byteFilter.isFilteringActive
    }

    var isDeadlineReached: Bool {
        byteFilter.isFilteringActive && (deadlineReached?() == true)
    }

    var remainingDeadlineMilliseconds: Int64? {
        guard byteFilter.isFilteringActive else { return nil }
        return remainingDeadline?()
    }

}
