import Darwin
import Foundation

extension RemoteHookInvocationBridge {
    func captureProcessOutput(
        _ process: Process,
        outputPipe: Pipe,
        errorPipe: Pipe,
        timeout: TimeInterval,
        maximumBytes: Int
    ) throws -> (stdout: Data, stderr: Data) {
        var captureCompleted = false
        defer {
            if !captureCompleted {
                terminateProcess(process)
            }
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let queue = kqueue()
        guard queue >= 0 else {
            terminateProcess(process)
            throw internalProcessError()
        }
        defer { Darwin.close(queue) }

        let outputFD = outputHandle.fileDescriptor
        let errorFD = errorHandle.fileDescriptor
        try makeNonblocking(outputFD)
        try makeNonblocking(errorFD)
        var readChanges = [outputFD, errorFD].map { descriptor in
            kevent(
                ident: UInt(descriptor),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                fflags: 0,
                data: 0,
                udata: nil
            )
        }
        let readRegistration = readChanges.withUnsafeMutableBufferPointer { changes in
            kevent(queue, changes.baseAddress, Int32(changes.count), nil, 0, nil)
        }
        guard readRegistration == 0 else {
            terminateProcess(process)
            throw internalProcessError()
        }

        var processExited = !process.isRunning
        if processExited {
            process.waitUntilExit()
        } else {
            var processChange = kevent(
                ident: UInt(process.processIdentifier),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT),
                data: 0,
                udata: nil
            )
            if kevent(queue, &processChange, 1, nil, 0, nil) != 0 {
                if errno == ESRCH {
                    process.waitUntilExit()
                    processExited = true
                } else {
                    terminateProcess(process)
                    throw internalProcessError()
                }
            }
        }

        var stdout = Data()
        var stderr = Data()
        stdout.reserveCapacity(min(maximumBytes, 64 * 1024))
        stderr.reserveCapacity(min(maximumBytes, 16 * 1024))
        var outputClosed = false
        var errorClosed = false
        let deadline = Date().addingTimeInterval(timeout)

        while !processExited || !outputClosed || !errorClosed {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                terminateProcess(process)
                throw bridgeError(
                    "timed_out",
                    key: "socket.hooks.remoteBridge.timedOut",
                    fallback: "The remote hook command timed out."
                )
            }
            var timeoutSpec = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
            )
            var triggeredEvents = Array(repeating: Darwin.kevent(), count: 3)
            let eventCount = triggeredEvents.withUnsafeMutableBufferPointer { buffer in
                kevent(queue, nil, 0, buffer.baseAddress, Int32(buffer.count), &timeoutSpec)
            }
            if eventCount == 0 {
                terminateProcess(process)
                throw bridgeError(
                    "timed_out",
                    key: "socket.hooks.remoteBridge.timedOut",
                    fallback: "The remote hook command timed out."
                )
            }
            if eventCount < 0 {
                if errno == EINTR { continue }
                terminateProcess(process)
                throw internalProcessError()
            }

            for event in triggeredEvents.prefix(Int(eventCount)) {
                if event.filter == Int16(EVFILT_PROC) {
                    process.waitUntilExit()
                    processExited = true
                    continue
                }
                guard event.filter == Int16(EVFILT_READ) else { continue }
                if event.ident == UInt(outputFD) {
                    outputClosed = try drain(
                        outputFD,
                        into: &stdout,
                        combinedWith: stderr.count,
                        maximumBytes: maximumBytes
                    ) || event.flags & UInt16(EV_EOF) != 0
                } else if event.ident == UInt(errorFD) {
                    errorClosed = try drain(
                        errorFD,
                        into: &stderr,
                        combinedWith: stdout.count,
                        maximumBytes: maximumBytes
                    ) || event.flags & UInt16(EV_EOF) != 0
                }
            }
        }
        captureCompleted = true
        return (stdout, stderr)
    }

    func waitForProcessExit(_ process: Process, timeout: TimeInterval) throws -> Bool {
        if !process.isRunning {
            process.waitUntilExit()
            return true
        }

        let queue = kqueue()
        guard queue >= 0 else { throw internalProcessError() }
        defer { Darwin.close(queue) }
        var event = kevent(
            ident: UInt(process.processIdentifier),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            if errno == ESRCH {
                process.waitUntilExit()
                return true
            }
            throw internalProcessError()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var timeoutSpec = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
            )
            var triggeredEvent = kevent()
            let result = kevent(queue, nil, 0, &triggeredEvent, 1, &timeoutSpec)
            if result > 0 {
                process.waitUntilExit()
                return true
            }
            if result == 0 { return false }
            if errno != EINTR { throw internalProcessError() }
        }
    }

    func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        if ((try? waitForProcessExit(process, timeout: 2)) ?? false) == false {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = try? waitForProcessExit(process, timeout: 1)
        }
    }

    private func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw internalProcessError()
        }
    }

    private func drain(
        _ descriptor: Int32,
        into data: inout Data,
        combinedWith otherCount: Int,
        maximumBytes: Int
    ) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + otherCount + count <= maximumBytes else {
                    throw bridgeError(
                        "resource_exhausted",
                        key: "socket.hooks.remoteBridge.outputTooLarge",
                        fallback: "Remote hook output exceeds the relay limit."
                    )
                }
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { return true }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            if errno != EINTR { throw internalProcessError() }
        }
    }

    private func internalProcessError() -> BridgeError {
        bridgeError(
            "internal_error",
            key: "socket.hooks.remoteBridge.failed",
            fallback: "The remote hook bridge failed."
        )
    }
}
