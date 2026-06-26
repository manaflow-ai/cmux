import CmuxFoundation
import AppKit
import Foundation

@MainActor
final class CloudVMActionLauncher {
    static let shared = CloudVMActionLauncher()

    struct Completion {
        let terminationStatus: Int32
        let output: String
        let workspaceId: UUID?

        var succeeded: Bool {
            terminationStatus == 0
        }
    }

    private var processes: [Int32: Process] = [:]
    private var progressControllers: [Int32: CloudVMActionProgressController] = [:]
    private var isShuttingDown = false

    private init() {}

    func terminateAll() {
        isShuttingDown = true
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
        for controller in progressControllers.values {
            controller.close()
        }
        progressControllers.removeAll()
    }

    @discardableResult
    func start(
        socketPath: String,
        preferredWindow: NSWindow?,
        arguments: [String] = ["vm", "base", "open"],
        successTitle: String? = nil,
        presentOutputOnSuccess: Bool = false,
        showsProgress: Bool = true,
        presentsFailureAlert: Bool = true,
        environmentOverrides: [String: String] = [:],
        onCompletion: ((Completion) -> Void)? = nil
    ) -> Bool {
        let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        guard let cliURL,
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            if presentsFailureAlert {
                presentStartFailure(
                    summary: String(
                        localized: "command.cloudVM.failed.missingCLI",
                        defaultValue: "The bundled cmux CLI is missing from this app build."
                    ),
                    output: "",
                    action: String(
                        localized: "command.cloudVM.failed.action.missingCLI",
                        defaultValue: "Install or reload a fresh cmux build, then try Start Cloud VM again. You can also run `cmux vm base open` in a terminal to see the full error."
                    ),
                    preferredWindow: preferredWindow
                )
            }
            return false
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--socket", socketPath, "--id-format", "uuids"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputCollector = ProcessOutputCollector(stdout: outputPipe, stderr: errorPipe)
        outputCollector.start()
        let launchWindow = preferredWindow
        let presentation = Self.progressPresentation(arguments: arguments)
        let progressController = showsProgress
            ? CloudVMActionProgressController(
                title: presentation.title,
                message: presentation.message,
                preferredWindow: preferredWindow
            )
            : nil
        process.terminationHandler = { terminatedProcess in
            let output = outputCollector.finish()
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                Self.shared.processes.removeValue(forKey: processIdentifier)
                Self.shared.progressControllers.removeValue(forKey: processIdentifier)?.close()
                onCompletion?(
                    Completion(
                        terminationStatus: terminationStatus,
                        output: output,
                        workspaceId: Self.createdWorkspaceId(from: output)
                    )
                )
                if terminationStatus == 0, presentOutputOnSuccess, !Self.shared.isShuttingDown {
                    Self.shared.presentCommandResult(
                        title: successTitle ?? String(localized: "command.cloudVM.result.title", defaultValue: "Cloud VM"),
                        output: output,
                        preferredWindow: launchWindow
                    )
                }
                guard terminationStatus != 0, !Self.shared.isShuttingDown, presentsFailureAlert else { return }
                let format = String(
                    localized: "command.cloudVM.failed.exit",
                    defaultValue: "Cloud VM command exited with status %d."
                )
                Self.shared.presentStartFailure(
                    summary: String(format: format, Int(terminationStatus)),
                    output: output,
                    action: String(
                        localized: "command.cloudVM.failed.action.exit",
                        defaultValue: "Open a terminal and run `cmux auth status`, `cmux vm ls`, then `cmux vm base open`. If you hit the active VM limit, delete one with `cmux vm rm <id>` and retry."
                    ),
                    preferredWindow: launchWindow
                )
            }
        }

        do {
            progressController?.show()
            try process.run()
            processes[process.processIdentifier] = process
            if let progressController {
                progressControllers[process.processIdentifier] = progressController
            }
#if DEBUG
            cmuxDebugLog("cloudVM.launch pid=\(process.processIdentifier) socket=\(socketPath)")
#endif
            return true
        } catch {
            outputCollector.cancel()
            progressController?.close()
            if presentsFailureAlert {
                presentStartFailure(
                    summary: String(
                        localized: "command.cloudVM.failed.launch",
                        defaultValue: "cmux vm base open could not be launched."
                    ),
                    output: error.localizedDescription,
                    action: String(
                        localized: "command.cloudVM.failed.action.launch",
                        defaultValue: "Reload cmux so the bundled CLI is available, then try again. If it still fails, run `cmux vm base open` in a terminal and send us the output."
                    ),
                    preferredWindow: preferredWindow
                )
            }
            return false
        }
    }

    private func presentCommandResult(title: String, output: String, preferredWindow: NSWindow?) {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = String(trimmedOutput.prefix(4000))
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let preferredWindow {
            alert.beginSheetModal(for: preferredWindow, completionHandler: nil)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    private static func createdWorkspaceId(from output: String) -> UUID? {
        for token in output.split(whereSeparator: \.isWhitespace) {
            let string = String(token)
            guard string.hasPrefix("workspace=") else { continue }
            let rawValue = String(string.dropFirst("workspace=".count))
            if let id = UUID(uuidString: rawValue) {
                return id
            }
        }
        return nil
    }

    private struct ProgressPresentation {
        let title: String
        let message: String
    }

    private static func progressPresentation(arguments: [String]) -> ProgressPresentation {
        if arguments.starts(with: ["vm", "base"]) || arguments.starts(with: ["vm", "new"]) {
            return ProgressPresentation(
                title: String(localized: "command.cloudVM.loading.open.title", defaultValue: "Opening Base"),
                message: String(localized: "command.cloudVM.loading.open.message", defaultValue: "Creating or reattaching to your persistent cloud workspace.")
            )
        }
        if arguments.contains("fork") {
            return ProgressPresentation(
                title: String(localized: "command.cloudVM.loading.fork.title", defaultValue: "Forking Cloud VM"),
                message: String(localized: "command.cloudVM.loading.fork.message", defaultValue: "Creating a copy of the selected Cloud VM.")
            )
        }
        if arguments.contains("snapshot") {
            return ProgressPresentation(
                title: String(localized: "command.cloudVM.loading.snapshot.title", defaultValue: "Checkpointing Cloud VM"),
                message: String(localized: "command.cloudVM.loading.snapshot.message", defaultValue: "Saving a checkpoint for the selected Cloud VM.")
            )
        }
        if arguments.contains("restore") {
            return ProgressPresentation(
                title: String(localized: "command.cloudVM.loading.restore.title", defaultValue: "Restoring Cloud VM"),
                message: String(localized: "command.cloudVM.loading.restore.message", defaultValue: "Starting a Cloud VM from the selected checkpoint.")
            )
        }
        return ProgressPresentation(
            title: String(localized: "command.cloudVM.loading.command.title", defaultValue: "Cloud VM"),
            message: String(localized: "command.cloudVM.loading.command.message", defaultValue: "Running Cloud VM command.")
        )
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

@MainActor
private final class CloudVMActionProgressController {
    private let panel: NSPanel
    private weak var preferredWindow: NSWindow?

    init(title: String, message: String, preferredWindow: NSWindow?) {
        self.preferredWindow = preferredWindow
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
            styleMask: [.hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.contentView = Self.makeContentView(title: title, message: message)
    }

    func show() {
        if let window = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow {
            let frame = window.frame
            let origin = NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - panel.frame.height - 56
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    private static func makeContentView(title: String, message: String) -> NSView {
        let root = NSVisualEffectView()
        root.blendingMode = .behindWindow
        root.material = .hudWindow
        root.state = .active

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(spinner)
        root.addSubview(titleLabel)
        root.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])

        return root
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
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.append(data, to: .stdout)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.append(data, to: .stderr)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
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
        append(stdoutHandle.readDataToEndOfFileOrEmpty(), to: .stdout)
        append(stderrHandle.readDataToEndOfFileOrEmpty(), to: .stderr)
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
