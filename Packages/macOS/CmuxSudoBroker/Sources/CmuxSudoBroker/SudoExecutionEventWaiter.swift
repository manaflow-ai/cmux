import Darwin
import Foundation

/// Waits for execution exit, password fallback, or the independent deadline.
struct SudoExecutionEventWaiter: Sendable {
    private let inspector: any SudoProcessInspecting

    init(inspector: any SudoProcessInspecting) {
        self.inspector = inspector
    }

    /// Drains pipes from kernel events so output stays bounded without blocking the child.
    func wait(
        for process: SudoSpawnedProcess,
        after timeout: TimeInterval
    ) -> SudoExecutionWaitDisposition {
        var descriptors = process.io.takeDescriptors()
        guard descriptors.output >= 0, descriptors.outputFile >= 0 else {
            Self.close(&descriptors)
            return .failed
        }
        var collector = SudoExecutionOutputCollector(
            outputDescriptor: descriptors.outputFile,
            readinessMarker: process.standardInputReadyMarker,
            controlMarkers: process.controlMarkers
        )
        var inputOffset = 0
        var inputWriteRegistered = false
        defer {
            try? collector.finish()
            Self.close(&descriptors)
        }

        do {
            try collector.drain(from: descriptors.output)
        } catch {
            return .failed
        }
        if process.standardInput != nil, descriptors.input < 0 { return .failed }
        if collector.authenticationFailed { return .authenticationFailed }
        guard inspector.isRunning(process.identity) else {
            return collector.privilegedFailure ?? .exited
        }
        guard timeout > 0 else { return .timedOut }

        let queue = kqueue()
        guard queue >= 0 else { return .failed }
        defer { Darwin.close(queue) }

        var processEvent = kevent(
            ident: UInt(process.identity.processIdentifier),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard Self.register(&processEvent, on: queue) else {
            return inspector.isRunning(process.identity) ? .failed : .exited
        }

        var outputEvent = kevent(
            ident: UInt(descriptors.output),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: 0,
            data: 0,
            udata: nil
        )
        guard Self.register(&outputEvent, on: queue) else { return .failed }

        let timerIdentifier = UInt.max
        var timerEvent = kevent(
            ident: timerIdentifier,
            filter: Int16(EVFILT_TIMER),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: 0,
            data: SudoKeventTimeout(seconds: timeout).milliseconds,
            udata: nil
        )
        guard Self.register(&timerEvent, on: queue) else { return .failed }

        while true {
            do {
                if collector.inputReady,
                   process.standardInput != nil,
                   !(try Self.writeInput(
                       process.standardInput,
                       descriptor: &descriptors.input,
                       offset: &inputOffset
                   )),
                   !inputWriteRegistered {
                    var inputEvent = kevent(
                        ident: UInt(descriptors.input),
                        filter: Int16(EVFILT_WRITE),
                        flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                        fflags: 0,
                        data: 0,
                        udata: nil
                    )
                    guard Self.register(&inputEvent, on: queue) else { return .failed }
                    inputWriteRegistered = true
                }
            } catch {
                return .failed
            }

            if collector.authenticationFailed { return .authenticationFailed }
            if !inspector.isRunning(process.identity) {
                do {
                    try collector.drain(from: descriptors.output)
                } catch {
                    return .failed
                }
                return collector.authenticationFailed
                    ? .authenticationFailed
                    : collector.privilegedFailure ?? .exited
            }

            var triggeredEvent = kevent()
            guard Self.receive(&triggeredEvent, from: queue) > 0 else { return .failed }
            if triggeredEvent.flags & UInt16(EV_ERROR) != 0,
               triggeredEvent.data != 0 {
                return .failed
            }

            if triggeredEvent.filter == Int16(EVFILT_READ),
               triggeredEvent.ident == UInt(descriptors.output) {
                do {
                    try collector.drain(from: descriptors.output)
                } catch {
                    return .failed
                }
                continue
            }
            if triggeredEvent.filter == Int16(EVFILT_WRITE),
               descriptors.input >= 0,
               triggeredEvent.ident == UInt(descriptors.input) {
                do {
                    if try Self.writeInput(
                        process.standardInput,
                        descriptor: &descriptors.input,
                        offset: &inputOffset
                    ) {
                        inputWriteRegistered = false
                    }
                } catch {
                    return .failed
                }
                continue
            }
            if triggeredEvent.filter == Int16(EVFILT_TIMER),
               triggeredEvent.ident == timerIdentifier {
                do {
                    try collector.drain(from: descriptors.output)
                } catch {
                    return .failed
                }
                if collector.authenticationFailed { return .authenticationFailed }
                if inspector.isRunning(process.identity) { return .timedOut }
                return collector.privilegedFailure ?? .exited
            }
        }
    }

    private static func writeInput(
        _ data: Data?,
        descriptor: inout Int32,
        offset: inout Int
    ) throws -> Bool {
        guard let data else { return true }
        guard descriptor >= 0 else { return offset == data.count }
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else {
                throw Failure.write(count == 0 ? EIO : errno)
            }
        }
        Darwin.close(descriptor)
        descriptor = -1
        return true
    }

    private static func close(_ descriptors: inout SudoSpawnedProcessIO.Descriptors) {
        for descriptor in Set([
            descriptors.input,
            descriptors.output,
            descriptors.outputFile,
        ]) where descriptor >= 0 {
            Darwin.close(descriptor)
        }
        descriptors = .init(input: -1, output: -1, outputFile: -1)
    }

    private static func register(_ event: inout kevent, on queue: Int32) -> Bool {
        var result: Int32
        repeat {
            result = kevent(queue, &event, 1, nil, 0, nil)
        } while result < 0 && errno == EINTR
        return result == 0
    }

    private static func receive(_ event: inout kevent, from queue: Int32) -> Int32 {
        var result: Int32
        repeat {
            result = kevent(queue, nil, 0, &event, 1, nil)
        } while result < 0 && errno == EINTR
        return result
    }

    private enum Failure: Error {
        case write(Int32)
    }
}
