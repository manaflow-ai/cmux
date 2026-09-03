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
        /// The machine the CLI reported creating, parsed from its stable
        /// `machine=<id>` token — never from localized display text.
        var machineId: String? = nil

        var succeeded: Bool {
            terminationStatus == 0
        }
    }

    private var processes: [Int32: Process] = [:]
    private var authTransitionSuppressedProcessIDs: Set<Int32> = []
    private var isShuttingDown = false

    private init() {}

    func terminateAll() {
        isShuttingDown = true
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
    }

    /// Cancel Cloud VM CLI children when the account is signing out without
    /// putting the launcher into the permanent application-termination state.
    /// Their late termination callbacks are suppressed so a failed CLI cannot
    /// present an alert over the signed-out account screen.
    func cancelAllForAuthTransition() {
        for (processID, process) in processes where process.isRunning {
            authTransitionSuppressedProcessIDs.insert(processID)
            process.terminate()
        }
        processes.removeAll()
    }

    @discardableResult
    func start(
        socketPath: String,
        preferredWindow: NSWindow?,
        arguments: [String] = ["vm", "base", "open"],
        successTitle: String? = nil,
        presentOutputOnSuccess: Bool = false,
        presentsFailureAlert: Bool = true,
        environmentOverrides: [String: String] = [:],
        onOutput: (@MainActor (String) -> Void)? = nil,
        onCompletion: ((Completion) -> Void)? = nil
    ) -> Bool {
        let accountFlow = AppDelegate.shared?.auth?.accountFlow
        let authState = CloudVMPanelAuthState.resolve(
            isAuthenticated: accountFlow?.isAuthenticated == true,
            isWorkingOnAuth: accountFlow?.isWorkingOnAuth == true
        )
        if !authState.allowsAuthenticatedOperation {
            // Keep every native launcher entrypoint aligned with the Machines
            // panel: a signed-out action opens the shared sign-in screen and
            // never starts a child CLI that could create or attach a VM.
            _ = AppDelegate.shared?.performAccountSignInWorkspaceAction(
                preferredWindow: preferredWindow,
                debugSource: "cloudVM.auth"
            )
            return false
        }
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
        let outputDelivery = onOutput.map { MainActorOutputCoalescer(handler: $0) }
        let outputCollector = ProcessOutputCollector(stdout: outputPipe, stderr: errorPipe) { chunk in
            outputDelivery?.enqueue(chunk)
        }
        outputCollector.start()
        let launchWindow = preferredWindow
        process.terminationHandler = { terminatedProcess in
            let result = outputCollector.finishResult()
            outputDelivery?.finish()
            let output = result.output
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                Self.shared.processes.removeValue(forKey: processIdentifier)
                let suppressPresentation = Self.shared.authTransitionSuppressedProcessIDs.remove(processIdentifier) != nil
                onCompletion?(
                    Completion(
                        terminationStatus: terminationStatus,
                        output: output,
                        workspaceId: Self.createdWorkspaceId(from: output),
                        machineId: result.machineId
                    )
                )
                if terminationStatus == 0, presentOutputOnSuccess, !Self.shared.isShuttingDown, !suppressPresentation {
                    Self.shared.presentCommandResult(
                        title: successTitle ?? String(localized: "command.cloudVM.result.title", defaultValue: "Cloud VM"),
                        output: output,
                        preferredWindow: launchWindow
                    )
                }
                guard terminationStatus != 0,
                      !Self.shared.isShuttingDown,
                      !suppressPresentation,
                      presentsFailureAlert else { return }
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
            try process.run()
            processes[process.processIdentifier] = process
#if DEBUG
            cmuxDebugLog("cloudVM.launch pid=\(process.processIdentifier) socket=\(socketPath)")
#endif
            return true
        } catch {
            outputCollector.cancel()
            outputDelivery?.finish()
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
        let trimmedOutput = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        // House alert style: command output lives in the scrollable details
        // region so long results never balloon the sheet.
        let content = CmuxAlertContent.scrollingAll(trimmedOutput)
        let window = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        content.apply(to: alert, presentingWindow: window)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    /// `cmux vm new` prints `OK machine=<id>` the moment the machine exists,
    /// before it tries to open it, so a failed open still reports the machine.
    nonisolated static func createdMachineId(from stdout: String) -> String? {
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("OK machine=") else { continue }
            let payload = line.dropFirst("OK machine=".count)
            let id = payload.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { continue }
            let suffix = payload.dropFirst(id.count)
            guard suffix.isEmpty || suffix.first?.isWhitespace == true else { continue }
            return id
        }
        return nil
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

    private func presentStartFailure(summary: String, output: String, action: String, preferredWindow: NSWindow?) {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let limitedOutput = String(trimmedOutput.prefix(2000))
        let safeOutput = Self.sanitizedCloudVMStartOutput(limitedOutput)
        // When the whole transcript is held back (it mentions backend internals),
        // still tell the person *why* it failed: the CLI's first line is the
        // human-readable reason ("Cloud VM state is unavailable (HTTP 503 …)").
        let reason = safeOutput.isEmpty ? Self.firstSafeLine(of: limitedOutput) : nil
        let whatToTry = String(localized: "command.cloudVM.failed.whatToTry", defaultValue: "What to try:")
        let details = String(localized: "command.cloudVM.failed.details", defaultValue: "Details:")
        var sections = [
            reason.map { "\(summary)\n\($0)" } ?? summary,
            "\(whatToTry)\n\(action)",
        ]
        if !safeOutput.isEmpty {
            sections.append("\(details)\n\(safeOutput)")
        }
        let informativeText = sections.joined(separator: "\n\n")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "command.cloudVM.failed.title", defaultValue: "Couldn't Start Cloud VM")
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        // House alert style: summary and next steps stay fixed, raw output
        // scrolls, and the sheet is attached to the window so it moves with it.
        let content = safeOutput.isEmpty
            ? CmuxAlertContent(informativeText: informativeText)
            : CmuxAlertContent(flattenedText: informativeText, separatingScrollableDetails: safeOutput)
        let window = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        content.apply(to: alert, presentingWindow: window)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    /// What replaces output that cannot be shown: the person is told details
    /// exist without the transcript leaking anything the redaction blocks.
    nonisolated static var hiddenOutputPlaceholder: String {
        String(
            localized: "command.cloudVM.failed.details.hidden",
            defaultValue: "Additional technical details are available in logs."
        )
    }

    /// The first line of CLI output that passes the same redaction as the full
    /// transcript, with an "Error:" prefix dropped. Nil when no line is safe.
    nonisolated static func firstSafeLine(of output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("error:") {
                line = String(line.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            let safe = sanitizedCloudVMStartOutput(line)
            if !safe.isEmpty, safe != hiddenOutputPlaceholder { return String(safe.prefix(240)) }
        }
        return nil
    }

    nonisolated static func sanitizedCloudVMStartOutput(_ output: String) -> String {
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
            return hiddenOutputPlaceholder
        }
        return trimmed
    }
}

/// Delivers bounded stdout progress through one consumer task. `AsyncStream`
/// owns synchronization and drops the oldest chunks when its finite buffer is
/// full, so pipe callbacks never create an unbounded MainActor task fanout.
final class MainActorOutputCoalescer: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let deliveryTask: Task<Void, Never>

    init(
        handler: @escaping @MainActor (String) -> Void,
        onTermination: (@Sendable () -> Void)? = nil
    ) {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(128))
        continuation = pair.continuation
        pair.continuation.onTermination = { @Sendable _ in
            onTermination?()
        }
        deliveryTask = Task {
            for await data in pair.stream {
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                guard !text.isEmpty else { continue }
                await MainActor.run { handler(text) }
            }
        }
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        continuation.yield(data)
    }

    /// Finish the stream after the process has delivered its final output.
    /// The delivery task then drains any buffered chunks and exits.
    func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
        deliveryTask.cancel()
    }
}

struct ProcessOutputResult: Sendable, Equatable {
    let output: String
    let stdout: String
    let machineId: String?
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
    private var stdoutPendingUTF8 = Data()
    private var stderrPendingUTF8 = Data()
    private var stdoutProtocolLine = Data()
    private var observedMachineID: String?
    private var isFinished = false

    private let onOutput: ((Data) -> Void)?

    init(stdout: Pipe, stderr: Pipe, onOutput: ((Data) -> Void)? = nil) {
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
        self.onOutput = onOutput
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
        finishResult().output
    }

    func finishResult() -> ProcessOutputResult {
        lock.lock()
        if isFinished {
            let output = formattedResultLocked()
            lock.unlock()
            return output
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        append(stdoutHandle.readDataToEndOfFileOrEmpty(), to: .stdout)
        append(stderrHandle.readDataToEndOfFileOrEmpty(), to: .stderr)
        lock.lock()
        finishPendingUTF8Locked()
        lock.unlock()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        lock.lock()
        finishProtocolObservation()
        let output = formattedResultLocked()
        lock.unlock()
        return output
    }

    func cancel() {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        lock.lock()
        finishPendingUTF8Locked()
        lock.unlock()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    private func append(_ data: Data, to stream: Stream) {
        guard !data.isEmpty else { return }
        onOutput?(data)
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .stdout:
            observeMachineID(in: data)
            appendBounded(data, to: &stdout, pending: &stdoutPendingUTF8)
        case .stderr:
            appendBounded(data, to: &stderr, pending: &stderrPendingUTF8)
        }
    }

    private func appendBounded(_ data: Data, to buffer: inout Data, pending: inout Data) {
        var combined = pending
        combined.append(data)
        let decoded = decodeUTF8(combined)
        pending = decoded.pending
        buffer.append(decoded.valid)
        let overflow = buffer.count - byteLimit
        if overflow > 0 {
            buffer.removeSubrange(0..<min(overflow, buffer.count))
        }
        while let first = buffer.first, (first & 0xC0) == 0x80 { buffer.removeFirst() }
    }

    private func decodeUTF8(_ data: Data) -> (valid: Data, pending: Data) {
        var valid = Data()
        valid.reserveCapacity(data.count)
        var index = 0
        while index < data.count {
            let byte = data[index]
            let width: Int
            switch byte {
            case 0x00...0x7F: width = 1
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default:
                index += 1
                continue
            }
            guard index + width <= data.count else {
                return (valid, Data(data[index...]))
            }
            if isValidUTF8Sequence(in: data, at: index, width: width) {
                valid.append(contentsOf: data[index..<(index + width)])
                index += width
            } else {
                // Skip only the malformed leading byte. The following bytes
                // may begin a valid sequence and must be examined again.
                index += 1
            }
        }
        return (valid, Data())
    }

    private func isValidUTF8Sequence(in data: Data, at index: Int, width: Int) -> Bool {
        guard width > 1 else { return true }
        let first = data[index]
        let second = data[index + 1]
        guard (second & 0xC0) == 0x80 else { return false }
        if first == 0xE0, second < 0xA0 { return false }
        if first == 0xED, second >= 0xA0 { return false }
        if first == 0xF0, second < 0x90 { return false }
        if first == 0xF4, second >= 0x90 { return false }
        for offset in 2..<width where (data[index + offset] & 0xC0) != 0x80 {
            return false
        }
        return true
    }

    private func finishPendingUTF8Locked() {
        if !stdoutPendingUTF8.isEmpty {
            stdout.append(String(decoding: stdoutPendingUTF8, as: UTF8.self).data(using: .utf8) ?? Data())
            stdoutPendingUTF8.removeAll(keepingCapacity: false)
            trimToByteLimit(&stdout)
        }
        if !stderrPendingUTF8.isEmpty {
            stderr.append(String(decoding: stderrPendingUTF8, as: UTF8.self).data(using: .utf8) ?? Data())
            stderrPendingUTF8.removeAll(keepingCapacity: false)
            trimToByteLimit(&stderr)
        }
    }

    private func trimToByteLimit(_ buffer: inout Data) {
        let overflow = buffer.count - byteLimit
        guard overflow > 0 else { return }
        buffer.removeSubrange(0..<overflow)
        while let first = buffer.first, (first & 0xC0) == 0x80 { buffer.removeFirst() }
    }

    private func finishProtocolObservation() {
        guard observedMachineID == nil,
              let text = String(data: stdoutProtocolLine, encoding: .utf8) else { return }
        observedMachineID = CloudVMActionLauncher.createdMachineId(from: text)
    }

    private func observeMachineID(in data: Data) {
        guard observedMachineID == nil else { return }
        stdoutProtocolLine.append(data)
        while let newline = stdoutProtocolLine.firstIndex(of: 0x0A) {
            let line = stdoutProtocolLine.prefix(upTo: newline)
            stdoutProtocolLine.removeSubrange(...newline)
            if let text = String(data: line, encoding: .utf8),
               let machineID = CloudVMActionLauncher.createdMachineId(from: text) {
                observedMachineID = machineID
                return
            }
        }
        // Scan complete lines before bounding the incomplete suffix. A single
        // pipe read can contain the protocol line and much later output.
        if stdoutProtocolLine.count > 4096 {
            stdoutProtocolLine.removeSubrange(0..<(stdoutProtocolLine.count - 4096))
        }
    }

    private func formattedResultLocked() -> ProcessOutputResult {
        let output = String(data: stdout, encoding: .utf8) ?? ""
        let error = String(data: stderr, encoding: .utf8) ?? ""
        return ProcessOutputResult(
            output: [output, error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n"),
            stdout: output,
            machineId: observedMachineID
        )
    }
}
