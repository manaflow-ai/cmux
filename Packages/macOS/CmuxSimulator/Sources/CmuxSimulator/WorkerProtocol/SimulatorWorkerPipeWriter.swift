#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

private let simulatorWorkerPipeMaximumPollSliceMilliseconds: Int64 = 10
private let simulatorWorkerPipeAttosecondsPerMillisecond: Int64 = 1_000_000_000_000_000

/// Serializes bounded host-to-worker frames away from the supervising actor.
///
/// A pipe write can make partial progress before a nonblocking descriptor
/// reports `EAGAIN`. Once that happens the frame must either finish or the
/// connection must be discarded. This writer owns that invariant on one
/// dedicated thread, with one deadline spanning the frame header and payload.
final class SimulatorWorkerPipeWriter: @unchecked Sendable {
    private let state: SimulatorWorkerPipeWriterState
    private let thread: Thread

    init(
        writeFD: Int32,
        writeDeadline: Duration,
        failureHandler: @escaping @Sendable () -> Void
    ) {
        let state = SimulatorWorkerPipeWriterState(
            writeFD: writeFD,
            writeDeadline: max(.zero, writeDeadline),
            failureHandler: failureHandler
        )
        self.state = state
        thread = Thread {
            simulatorRunWorkerPipeWriter(state)
        }
        thread.name = "cmux-simulator-worker-writer"
        thread.stackSize = 1 << 20

        let flags = fcntl(writeFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(writeFD, F_SETFL, flags | O_NONBLOCK)
        }
        thread.start()
    }

    deinit {
        stop()
    }

    func enqueue(_ payload: Data) throws {
        state.condition.lock()
        defer { state.condition.unlock() }
        guard !state.isFinishing,
              !state.isStopping,
              !state.isPoisoned,
              state.outstandingCount
                < SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount else {
            throw SimulatorChannelError.writeFailed
        }
        state.payloads.append(payload)
        state.outstandingCount += 1
        state.condition.signal()
    }

    func finish(_ completion: @escaping @Sendable () -> Void) {
        let completeImmediately = state.condition.withLock { () -> Bool in
            guard !state.didExit else { return true }
            if state.finishHandler == nil {
                state.finishHandler = completion
            }
            state.isFinishing = true
            state.condition.broadcast()
            return false
        }
        if completeImmediately { completion() }
    }

    func stop() {
        state.condition.lock()
        state.isStopping = true
        state.payloads.removeAll()
        state.outstandingCount = 0
        state.condition.broadcast()
        while !state.didExit {
            state.condition.wait()
        }
        state.condition.unlock()
    }
}

private func simulatorRunWorkerPipeWriter(_ state: SimulatorWorkerPipeWriterState) {
    while let payload = simulatorNextWorkerPipePayload(state) {
        switch simulatorWriteWorkerPipeFrame(payload, state: state) {
        case .completed:
            state.condition.withLock {
                state.outstandingCount = max(0, state.outstandingCount - 1)
            }
        case .stopped:
            _ = simulatorFinishWorkerPipeWriter(state, poisoned: false)
            return
        case .failed:
            _ = simulatorFinishWorkerPipeWriter(state, poisoned: true)
            state.failureHandler()
            return
        }
    }
    simulatorFinishWorkerPipeWriter(state, poisoned: false)?()
}

private func simulatorNextWorkerPipePayload(_ state: SimulatorWorkerPipeWriterState) -> Data? {
    state.condition.lock()
    defer { state.condition.unlock() }
    while state.payloads.isEmpty, !state.isFinishing, !state.isStopping {
        state.condition.wait()
    }
    guard !state.isStopping, !state.payloads.isEmpty else { return nil }
    return state.payloads.removeFirst()
}

private func simulatorFinishWorkerPipeWriter(
    _ state: SimulatorWorkerPipeWriterState,
    poisoned: Bool
) -> (@Sendable () -> Void)? {
    state.condition.withLock {
        state.isPoisoned = state.isPoisoned || poisoned
        state.isStopping = true
        state.payloads.removeAll()
        state.outstandingCount = 0
        state.didExit = true
        state.condition.broadcast()
        let finishHandler = poisoned ? nil : state.finishHandler
        state.finishHandler = nil
        return finishHandler
    }
}

private func simulatorWriteWorkerPipeFrame(
    _ payload: Data,
    state: SimulatorWorkerPipeWriterState
) -> SimulatorWorkerPipeWriteOutcome {
    let count = UInt32(payload.count)
    let header = Data([
        UInt8((count >> 24) & 0xff),
        UInt8((count >> 16) & 0xff),
        UInt8((count >> 8) & 0xff),
        UInt8(count & 0xff),
    ])
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: state.writeDeadline)
    let headerOutcome = simulatorWriteAllWorkerPipeBytes(
        header,
        state: state,
        clock: clock,
        deadline: deadline
    )
    guard headerOutcome == .completed else { return headerOutcome }
    guard !payload.isEmpty else { return .completed }
    return simulatorWriteAllWorkerPipeBytes(
        payload,
        state: state,
        clock: clock,
        deadline: deadline
    )
}

private func simulatorWriteAllWorkerPipeBytes(
    _ data: Data,
    state: SimulatorWorkerPipeWriterState,
    clock: ContinuousClock,
    deadline: ContinuousClock.Instant
) -> SimulatorWorkerPipeWriteOutcome {
    data.withUnsafeBytes { raw in
        guard let baseAddress = raw.baseAddress else { return .completed }
        var offset = 0
        while offset < raw.count {
            if simulatorWorkerPipeShouldStop(state) { return .stopped }
            guard clock.now < deadline else { return .failed }
            let written = write(
                state.writeFD,
                baseAddress + offset,
                raw.count - offset
            )
            if written > 0 {
                offset += written
                continue
            }
            if written == -1, errno == EINTR {
                continue
            }
            if written == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                let outcome = simulatorWaitUntilWorkerPipeWritable(
                    state,
                    clock: clock,
                    deadline: deadline
                )
                guard outcome == .completed else { return outcome }
                continue
            }
            return .failed
        }
        return .completed
    }
}

private func simulatorWaitUntilWorkerPipeWritable(
    _ state: SimulatorWorkerPipeWriterState,
    clock: ContinuousClock,
    deadline: ContinuousClock.Instant
) -> SimulatorWorkerPipeWriteOutcome {
    while true {
        if simulatorWorkerPipeShouldStop(state) { return .stopped }
        guard let timeout = simulatorWorkerPipePollTimeoutMilliseconds(
            clock: clock,
            deadline: deadline
        ) else {
            return .failed
        }
        var descriptor = pollfd(fd: state.writeFD, events: Int16(POLLOUT), revents: 0)
        let result = poll(&descriptor, 1, timeout)
        if result > 0 {
            if descriptor.revents & Int16(POLLNVAL) != 0 { return .failed }
            if descriptor.revents & Int16(POLLOUT | POLLERR | POLLHUP) != 0 {
                return .completed
            }
            continue
        }
        if result == 0 { continue }
        if errno == EINTR { continue }
        return .failed
    }
}

private func simulatorWorkerPipePollTimeoutMilliseconds(
    clock: ContinuousClock,
    deadline: ContinuousClock.Instant
) -> Int32? {
    let remaining = clock.now.duration(to: deadline)
    guard remaining > .zero else { return nil }
    let components = remaining.components
    var milliseconds = components.seconds * 1_000
    if components.attoseconds > 0 {
        milliseconds += (
            components.attoseconds + simulatorWorkerPipeAttosecondsPerMillisecond - 1
        ) / simulatorWorkerPipeAttosecondsPerMillisecond
    }
    return Int32(clamping: max(
        1,
        min(simulatorWorkerPipeMaximumPollSliceMilliseconds, milliseconds)
    ))
}

private func simulatorWorkerPipeShouldStop(_ state: SimulatorWorkerPipeWriterState) -> Bool {
    state.condition.withLock { state.isStopping }
}
