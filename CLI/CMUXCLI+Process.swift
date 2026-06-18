import CmuxFoundation
import Darwin
import Foundation

struct CLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

struct CLIProcessDataResult {
    let status: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
}

private final class CLIProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}

enum CLIProcessRunner {
    static func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        let stdoutFinished = DispatchSemaphore(value: 0)
        let stderrFinished = DispatchSemaphore(value: 0)
        let stdoutBuffer = CLIProcessOutputBuffer()
        let stderrBuffer = CLIProcessOutputBuffer()

        DispatchQueue.global(qos: .utility).async {
            stdoutBuffer.set(stdoutPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stdoutFinished.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.set(stderrPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stderrFinished.signal()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            stdinPipe?.fileHandleForWriting.closeFile()
            stdoutFinished.wait()
            stderrFinished.wait()
            return CLIProcessResult(status: 1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut: Bool
        if let timeout {
            switch finished.wait(timeout: .now() + timeout) {
            case .success:
                timedOut = false
            case .timedOut:
                timedOut = true
                terminate(process: process, finished: finished)
            }
        } else {
            finished.wait()
            timedOut = false
        }

        stdoutFinished.wait()
        stderrFinished.wait()

        let stdout = String(data: stdoutBuffer.get(), encoding: .utf8) ?? ""
        var stderr = String(data: stderrBuffer.get(), encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "process timed out"
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = timeoutMessage
            } else if !stderr.contains(timeoutMessage) {
                stderr += "\n\(timeoutMessage)"
            }
        }

        return CLIProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    static func runProcessData(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> CLIProcessDataResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        let stdoutFinished = DispatchSemaphore(value: 0)
        let stderrFinished = DispatchSemaphore(value: 0)
        let stdoutBuffer = CLIProcessOutputBuffer()
        let stderrBuffer = CLIProcessOutputBuffer()

        DispatchQueue.global(qos: .utility).async {
            stdoutBuffer.set(stdoutPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stdoutFinished.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.set(stderrPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stderrFinished.signal()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            stdinPipe?.fileHandleForWriting.closeFile()
            stdoutFinished.wait()
            stderrFinished.wait()
            return CLIProcessDataResult(status: 1, stdout: Data(), stderr: error.localizedDescription, timedOut: false)
        }

        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut: Bool
        if let timeout {
            switch finished.wait(timeout: .now() + timeout) {
            case .success:
                timedOut = false
            case .timedOut:
                timedOut = true
                terminate(process: process, finished: finished)
            }
        } else {
            finished.wait()
            timedOut = false
        }

        stdoutFinished.wait()
        stderrFinished.wait()

        var stderr = String(data: stderrBuffer.get(), encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "process timed out"
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = timeoutMessage
            } else if !stderr.contains(timeoutMessage) {
                stderr += "\n\(timeoutMessage)"
            }
        }

        return CLIProcessDataResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdoutBuffer.get(),
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func terminate(process: Process, finished: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .success {
            return
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = finished.wait(timeout: .now() + 0.5)
    }
}
