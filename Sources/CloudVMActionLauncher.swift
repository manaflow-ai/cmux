import AppKit
import Foundation

@MainActor
final class CloudVMActionLauncher {
    static let shared = CloudVMActionLauncher()

    private var processes: [Int32: Process] = [:]
    private var isShuttingDown = false

    private init() {}

    func terminateAll() {
        isShuttingDown = true
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
    }

    @discardableResult
    func start(socketPath: String, preferredWindow: NSWindow?) -> Bool {
        let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        guard let cliURL,
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            presentStartFailure(
                summary: String(
                    localized: "command.cloudVM.failed.missingCLI",
                    defaultValue: "The bundled cmux CLI is missing from this app build."
                ),
                output: "",
                action: String(
                    localized: "command.cloudVM.failed.action.missingCLI",
                    defaultValue: "Install or reload a fresh cmux build, then try Start Cloud VM again. You can also run `cmux vm new` in a terminal to see the full error."
                ),
                preferredWindow: preferredWindow
            )
            return false
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--socket", socketPath, "vm", "new"]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputCollector = ProcessOutputCollector(stdout: outputPipe, stderr: errorPipe)
        outputCollector.start()
        let launchWindow = preferredWindow
        process.terminationHandler = { terminatedProcess in
            let output = outputCollector.finish()
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                Self.shared.processes.removeValue(forKey: processIdentifier)
                guard terminationStatus != 0, !Self.shared.isShuttingDown else { return }
                let format = String(
                    localized: "command.cloudVM.failed.exit",
                    defaultValue: "cmux vm new exited with status %d."
                )
                Self.shared.presentStartFailure(
                    summary: String(format: format, Int(terminationStatus)),
                    output: output,
                    action: String(
                        localized: "command.cloudVM.failed.action.exit",
                        defaultValue: "Open a terminal and run `cmux auth status`, `cmux vm ls`, then `cmux vm new`. If you hit the active VM limit, delete one with `cmux vm rm <id>` and retry."
                    ),
                    preferredWindow: launchWindow
                )
            }
        }

        do {
            try process.run()
            processes[process.processIdentifier] = process
#if DEBUG
            cmuxDebugLog("cloudVM.launch pid=\(process.processIdentifier) socket=\(socketPath)")
#endif
            return true
        } catch {
            outputCollector.cancel()
            presentStartFailure(
                summary: String(
                    localized: "command.cloudVM.failed.launch",
                    defaultValue: "cmux vm new could not be launched."
                ),
                output: error.localizedDescription,
                action: String(
                    localized: "command.cloudVM.failed.action.launch",
                    defaultValue: "Reload cmux so the bundled CLI is available, then try again. If it still fails, run `cmux vm new` in a terminal and send us the output."
                ),
                preferredWindow: preferredWindow
            )
            return false
        }
    }

    private func presentStartFailure(summary: String, output: String, action: String, preferredWindow: NSWindow?) {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let limitedOutput = String(trimmedOutput.prefix(2000))
        let safeOutput = sanitizedCloudVMStartOutput(limitedOutput)
        let whatToTry = String(localized: "command.cloudVM.failed.whatToTry", defaultValue: "What to try:")
        let details = String(localized: "command.cloudVM.failed.details", defaultValue: "Details:")
        var sections = [
            summary,
            "\(whatToTry)\n\(action)",
        ]
        if !safeOutput.isEmpty {
            sections.append("\(details)\n\(safeOutput)")
        }
        let informativeText = sections.joined(separator: "\n\n")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "command.cloudVM.failed.title", defaultValue: "Couldn't Start Cloud VM")
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let preferredWindow {
            alert.beginSheetModal(for: preferredWindow, completionHandler: nil)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    private func sanitizedCloudVMStartOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowercased = trimmed.lowercased()
        let normalized = lowercased
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        let blockedTerms = [
            "authorization",
            "aws_",
            "bearer",
            "billingcustomer",
            "billingteam",
            "cmux_vm_",
            "cookie",
            "credential",
            "database",
            "e2b",
            "freestyle",
            "http://",
            "https://",
            "itemid",
            "manifest",
            "migration",
            "postgres",
            "private key",
            "private_key",
            "provider",
            "rds",
            "refresh token",
            "refresh_token",
            "secret",
            "session id",
            "session_id",
            "snapshot",
            "stack auth",
            "token",
        ]
        let normalizedBlockedTerms = [
            "authorization",
            "aws",
            "bearer",
            "billingcustomer",
            "billingteam",
            "cmuxvmapi",
            "cookie",
            "credential",
            "database",
            "e2b",
            "freestyle",
            "itemid",
            "manifest",
            "migration",
            "postgres",
            "privatekey",
            "provider",
            "rds",
            "refreshtoken",
            "secret",
            "sessionid",
            "snapshot",
            "stackauth",
            "token",
        ]
        let containsBlockedTerm = blockedTerms.contains { lowercased.contains($0) }
            || normalizedBlockedTerms.contains { normalized.contains($0) }
        let containsLikelyEmail = trimmed.contains("@")
        let containsLikelyIPAddress = trimmed.range(
            of: #"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)"#,
            options: .regularExpression
        ) != nil
        let containsLikelyFilesystemPath = trimmed.range(
            of: #"(^|[\s"'(\[])(~[/\w.-]*|/(Users|home|private|var/folders)/|/[^ \n\t"'()]+/[^ \n\t"'()]+)"#,
            options: .regularExpression
        ) != nil
        guard !containsBlockedTerm,
              !containsLikelyEmail,
              !containsLikelyIPAddress,
              !containsLikelyFilesystemPath else {
            return String(
                localized: "command.cloudVM.failed.details.hidden",
                defaultValue: "Additional technical details are available in logs."
            )
        }
        return trimmed
    }
}

final class ProcessOutputCollector: @unchecked Sendable {
    private enum Stream {
        case stdout
        case stderr
    }

    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let lock = NSLock()
    private let byteLimit = 32 * 1024
    private var stdout = Data()
    private var stderr = Data()
    private var isFinished = false

    init(stdout: Pipe, stderr: Pipe) {
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
    }

    func start() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, to: .stdout)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, to: .stderr)
        }
    }

    @discardableResult
    func finish() -> String {
        lock.lock()
        guard !isFinished else {
            let output = formattedOutputLocked()
            lock.unlock()
            return output
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        append(stdoutHandle.readDataToEndOfFile(), to: .stdout)
        append(stderrHandle.readDataToEndOfFile(), to: .stderr)
        try? stdoutHandle.close()
        try? stderrHandle.close()

        lock.lock()
        let output = formattedOutputLocked()
        lock.unlock()
        return output
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    private func append(_ data: Data, to stream: Stream) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .stdout:
            appendBounded(data, to: &stdout)
        case .stderr:
            appendBounded(data, to: &stderr)
        }
    }

    private func appendBounded(_ data: Data, to buffer: inout Data) {
        guard data.count < byteLimit else {
            buffer = Data(data.suffix(byteLimit))
            return
        }

        let overflow = buffer.count + data.count - byteLimit
        if overflow > 0 {
            buffer.removeSubrange(0..<overflow)
        }
        buffer.append(data)
    }

    private func formattedOutputLocked() -> String {
        let output = String(data: stdout, encoding: .utf8) ?? ""
        let error = String(data: stderr, encoding: .utf8) ?? ""
        return [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
