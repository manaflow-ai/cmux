internal import Foundation
import Darwin

/// Owns the queues and POSIX operations used by one command runner.
struct CommandProcessOperations: Sendable {
    private let timerQueue = DispatchQueue(
        label: "com.cmuxterm.CmuxProcess.timer"
    )
    private let eventQueue = DispatchQueue(
        label: "com.cmuxterm.CmuxProcess.exit"
    )
    private let spawnQueue = DispatchQueue(
        label: "com.cmuxterm.CmuxProcess.spawn",
        qos: .utility,
        attributes: .concurrent
    )
    private let reapingQueue = DispatchQueue.global(qos: .utility)

    func makeDeadlineTimer() -> CommandTimer {
        CommandTimer(queue: timerQueue)
    }

    func makeExitSource(
        processIdentifier: pid_t
    ) -> CommandProcessExitSource {
        CommandProcessExitSource(
            processIdentifier: processIdentifier,
            queue: eventQueue
        )
    }

    func terminateOwnedProcessTree(processGroupID: pid_t) {
        if Darwin.killpg(processGroupID, SIGTERM) != 0, errno != ESRCH {
            _ = Darwin.kill(processGroupID, SIGTERM)
        }
        scheduleSigkill(processGroupID: processGroupID)
    }

    private func scheduleSigkill(processGroupID: pid_t) {
        let timer = CommandTimer(queue: timerQueue)
        timer.schedule(deadline: .now() + 0.2)
        timer.setEventHandler {
            _ = Darwin.killpg(processGroupID, SIGKILL)
            reapingQueue.async {
                reap(processIdentifier: processGroupID)
            }
            timer.cancel()
        }
        timer.resume()
    }

    func reap(processIdentifier: pid_t) {
        var rawStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = Darwin.waitpid(processIdentifier, &rawStatus, 0)
        } while waitResult == -1 && errno == EINTR
    }

    func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        directory: String,
        stdoutFileDescriptor: Int32,
        stderrFileDescriptor: Int32,
        fileDescriptorsToClose: [Int32]
    ) async throws -> pid_t {
        try await withCheckedThrowingContinuation { continuation in
            spawnQueue.async {
                do {
                    continuation.resume(returning: try spawnSynchronously(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: environment,
                        directory: directory,
                        stdoutFileDescriptor: stdoutFileDescriptor,
                        stderrFileDescriptor: stderrFileDescriptor,
                        fileDescriptorsToClose: fileDescriptorsToClose
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func spawnSynchronously(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        directory: String,
        stdoutFileDescriptor: Int32,
        stderrFileDescriptor: Int32,
        fileDescriptorsToClose: [Int32]
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try throwIfPOSIXError(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try "/dev/null".withCString { path in
            try throwIfPOSIXError(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                )
            )
        }
        try directory.withCString { path in
            try throwIfPOSIXError(
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            )
        }
        try throwIfPOSIXError(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stdoutFileDescriptor,
                STDOUT_FILENO
            )
        )
        try throwIfPOSIXError(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stderrFileDescriptor,
                STDERR_FILENO
            )
        )
        for descriptor in Set(fileDescriptorsToClose)
        where descriptor > STDERR_FILENO {
            try throwIfPOSIXError(
                posix_spawn_file_actions_addclose(&fileActions, descriptor)
            )
        }

        var attributes: posix_spawnattr_t?
        try throwIfPOSIXError(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_START_SUSPENDED
        )
        try throwIfPOSIXError(posix_spawnattr_setpgroup(&attributes, 0))
        try throwIfPOSIXError(posix_spawnattr_setflags(&attributes, flags))

        let argumentStrings = [executablePath] + arguments
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var processIdentifier: pid_t = 0
        let spawnStatus = try withMutableCStringArray(argumentStrings) {
            argumentPointers in
            try withMutableCStringArray(environmentStrings) {
                environmentPointers in
                executablePath.withCString { executablePointer in
                    posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        try throwIfPOSIXError(spawnStatus)
        guard processIdentifier > 1 else { throw POSIXError(.ECHILD) }
        return processIdentifier
    }

    private func throwIfPOSIXError(_ status: Int32) throws {
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
    }

    private func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) throws -> Result
    ) throws -> Result {
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw POSIXError(.EINVAL)
        }
        var pointers = try strings.map {
            string -> UnsafeMutablePointer<CChar>? in
            guard let pointer = strdup(string) else {
                throw POSIXError(.ENOMEM)
            }
            return pointer
        }
        pointers.append(nil)
        defer {
            for pointer in pointers.dropLast() {
                free(pointer)
            }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw POSIXError(.EINVAL)
            }
            return try body(baseAddress)
        }
    }

    func readOutputToEnd(
        fileDescriptor: Int32,
        captureLimit: Int?
    ) -> Data {
        var data = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes {
                pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, base, chunkSize)
            }
            if bytesRead > 0 {
                let bytesToCapture = captureLimit.map {
                    min(bytesRead, max(0, $0 - data.count))
                } ?? bytesRead
                if bytesToCapture > 0 {
                    data.append(contentsOf: buffer[0..<bytesToCapture])
                }
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }
}
