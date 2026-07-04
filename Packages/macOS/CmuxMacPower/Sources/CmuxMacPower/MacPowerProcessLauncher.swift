import Darwin
internal import Foundation

/// Launches Mac power helper processes.
struct MacPowerProcessLauncher {
    private let sigkillGraceSeconds: Double = 0.2
    private let timerQueue = DispatchQueue(label: "dev.cmux.mac-power-command-runner.timer")

    /// Launch `tool`, optionally capturing stdout.
    ///
    /// The stdout reader starts before spawn so a child cannot deadlock against a
    /// full pipe. A dispatch deadline bounds tools that stall behind OS prompts.
    func run(
        _ tool: String,
        _ arguments: [String],
        captureOutput: Bool,
        timeout: TimeInterval?
    ) async -> MacPowerRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let pipe: Pipe?
        if captureOutput {
            let outputPipe = Pipe()
            pipe = outputPipe
            process.standardOutput = outputPipe
        } else {
            pipe = nil
            process.standardOutput = FileHandle.nullDevice
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<MacPowerRunResult, Never>) in
            let state = MacPowerProcessRunState(captureOutput: captureOutput)
            let failure: MacPowerRunResult = (success: false, output: nil)

            if let pipe {
                let outputDescriptor = pipe.fileHandleForReading.fileDescriptor
                Task.detached {
                    let data = macPowerReadToEnd(fileDescriptor: outputDescriptor)
                    if let completed = await state.recordOutput(data) {
                        continuation.resume(returning: completed)
                    }
                }
            }

            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                Task {
                    if let completed = await state.recordTermination(status) {
                        continuation.resume(returning: completed)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                try? pipe?.fileHandleForWriting.close()
                Task {
                    if await state.claim(failure) {
                        continuation.resume(returning: failure)
                    }
                }
                return
            }

            try? pipe?.fileHandleForWriting.close()

            guard let timeout else { return }
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + max(timeout, 0))
            timer.setEventHandler {
                timer.cancel()
                Task {
                    if await state.claim(failure) {
                        continuation.resume(returning: failure)
                        if process.isRunning {
                            process.terminate()
                            self.scheduleSigkill(process)
                        }
                    }
                }
            }
            timer.resume()
        }
    }

    private func scheduleSigkill(_ process: Process) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + sigkillGraceSeconds)
        timer.setEventHandler {
            // Only SIGKILL if the Process is still running. If it already exited
            // during the grace window, the raw pid could now belong to another
            // process.
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            timer.cancel()
        }
        timer.resume()
    }
}

private func macPowerReadToEnd(fileDescriptor: Int32) -> Data {
    var data = Data()
    let chunkSize = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while true {
        let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return Darwin.read(fileDescriptor, baseAddress, chunkSize)
        }
        if bytesRead > 0 {
            data.append(contentsOf: buffer[0..<bytesRead])
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
