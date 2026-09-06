import CmuxFoundation
import CmuxSettings
import AppKit
import Foundation

@MainActor
final class CloudVMActionLauncher {
    static let shared = CloudVMActionLauncher()

    /// A handle for a caller-owned CLI operation. Cancelling the handle only
    /// stops that child process; the completion still arrives so its owner can
    /// reconcile any output emitted before termination.
    struct CancellationHandle {
        private let action: @MainActor () -> Void

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @MainActor
        func cancel() {
            action()
        }
    }

    struct Completion {
        let terminationStatus: Int32
        let output: String
        let workspaceId: UUID?
        /// The machine the CLI reported creating, parsed from its stable
        /// `machine=<id>` token — never from localized display text.
        var machineId: String? = nil
        /// True when the caller explicitly cancelled the child process. A
        /// cancelled create is not a failed create and must not present an
        /// error sheet or notification.
        var wasCancelled: Bool = false

        var succeeded: Bool {
            terminationStatus == 0
        }

        /// The CLI's not-found failure (`Cloud VM not found (HTTP 404: vm_not_found)`):
        /// the backend no longer knows the machine. For a delete that is the
        /// outcome the person asked for.
        var indicatesCloudVMNotFound: Bool {
            !succeeded && output.range(of: "vm_not_found", options: .caseInsensitive) != nil
        }
    }

    /// The verb-specific half of a failure alert. Every verb shares one alert
    /// shape (summary, what to try, scrollable details); the title and the
    /// advice belong to the verb, and a verb may declare some failures silent.
    struct FailurePresentation {
        var title: String
        var action: String
        /// True when this failure needs no alert. Deleting a machine the backend
        /// already forgot removes its row and workspaces (the `vm.destroy`
        /// handler cleans up on 404), which is what the person asked for.
        var isSilent: (Completion) -> Bool = { _ in false }

        static var startCloudVM: FailurePresentation {
            FailurePresentation(
                title: String(localized: "command.cloudVM.failed.title", defaultValue: "Couldn't Start Cloud VM"),
                action: String(
                    localized: "command.cloudVM.failed.action.exit",
                    defaultValue: "Open a terminal and run `cmux auth status`, `cmux vm ls`, then `cmux vm base open`. If you hit the active VM limit, delete one with `cmux vm rm <id>` and retry."
                )
            )
        }

        /// The presentation for one `cmux …` invocation, keyed on its verb, so
        /// every entrypoint (row menu, palette, ＋ menu) names what failed: a
        /// delete or a rename is never reported as "Couldn't Start Cloud VM".
        static func forCommand(_ arguments: [String]) -> FailurePresentation {
            let words = arguments.filter { !$0.hasPrefix("-") }
            guard words.first == "vm", words.count > 1 else { return startCloudVM }
            let generic = String(
                localized: "command.cloudVM.failed.action.generic",
                defaultValue: "Retry, or run the Cloud VM command in a terminal to see the full output."
            )
            switch words[1] {
            case "base", "new":
                return startCloudVM
            case "rm", "destroy", "delete":
                return FailurePresentation(
                    title: String(localized: "command.cloudVM.failed.title.delete", defaultValue: "Couldn't Delete Machine"),
                    action: String(
                        localized: "command.cloudVM.failed.action.delete",
                        defaultValue: "Refresh the Machines list and retry. A machine that no longer exists is removed from the list automatically. To see the full output, run `cmux vm rm <id>` in a terminal."
                    ),
                    isSilent: { $0.indicatesCloudVMNotFound }
                )
            case "rename":
                return FailurePresentation(
                    title: String(localized: "command.cloudVM.failed.title.rename", defaultValue: "Couldn't Rename Machine"),
                    action: String(
                        localized: "command.cloudVM.failed.action.rename",
                        defaultValue: "A label is printable text of at most 64 characters. Retry, or run `cmux vm rename <id> <label>` in a terminal to see the full output."
                    )
                )
            case "snapshot":
                return FailurePresentation(
                    title: String(localized: "command.cloudVM.failed.title.checkpoint", defaultValue: "Couldn't Checkpoint Machine"),
                    action: generic
                )
            case "fork":
                return FailurePresentation(
                    title: String(localized: "command.cloudVM.failed.title.fork", defaultValue: "Couldn't Fork Machine"),
                    action: generic
                )
            case "restore":
                return FailurePresentation(
                    title: String(localized: "command.cloudVM.failed.title.restore", defaultValue: "Couldn't Restore Checkpoint"),
                    action: generic
                )
            case "status":
                return FailurePresentation(
                    title: String(localized: "command.cloudVM.failed.title.status", defaultValue: "Couldn't Read Machine Status"),
                    action: generic
                )
            case "shell", "desktop", "open":
                return FailurePresentation(
                    title: String(localized: "command.cloudVM.failed.title.open", defaultValue: "Couldn't Open Machine"),
                    action: generic
                )
            default:
                return FailurePresentation(
                    title: String(localized: "command.cloudVM.failed.title.generic", defaultValue: "Cloud VM Command Failed"),
                    action: generic
                )
            }
        }
    }

    /// Tracks one launch token alongside its PID. Keeping this tiny registry
    /// separate makes the PID-reuse rule explicit: a deferred callback may
    /// remove an entry only when its token still matches the current entry.
    struct LaunchRegistry<Value> {
        struct Entry {
            let value: Value
            let launchID: UUID
        }

        private(set) var entries: [Int32: Entry] = [:]

        /// Records or replaces the launch currently occupying `processID`.
        mutating func insert(_ value: Value, processID: Int32, launchID: UUID) {
            entries[processID] = Entry(value: value, launchID: launchID)
        }

        /// Returns the entry for a PID without treating the PID as a complete
        /// identity; callers must compare its `launchID` before mutating it.
        func entry(processID: Int32) -> Entry? {
            entries[processID]
        }

        /// Removes an entry only when both the PID and launch token match.
        @discardableResult
        mutating func remove(processID: Int32, launchID: UUID) -> Value? {
            guard entries[processID]?.launchID == launchID else { return nil }
            return entries.removeValue(forKey: processID)?.value
        }

        mutating func removeAll() {
            entries.removeAll()
        }
    }

    private var processes = LaunchRegistry<Process>()
    private var authTransitionSuppressedLaunchIDs: Set<UUID> = []
    private var cancelledLaunchIDs: Set<UUID> = []
    private var isShuttingDown = false

    private init() {}

    func terminateAll() {
        isShuttingDown = true
        for tracked in processes.entries.values where tracked.value.isRunning {
            tracked.value.terminate()
        }
        processes.removeAll()
        authTransitionSuppressedLaunchIDs.removeAll()
        cancelledLaunchIDs.removeAll()
    }

    /// Cancel Cloud VM CLI children when the account is signing out without
    /// putting the launcher into the permanent application-termination state.
    /// Their late termination callbacks are suppressed so a failed CLI cannot
    /// present an alert over the signed-out account screen.
    func cancelAllForAuthTransition() {
        for tracked in processes.entries.values {
            // Mark every tracked launch, including one that has exited but whose
            // termination callback is still queued, so no late callback presents
            // an alert after the account transition.
            authTransitionSuppressedLaunchIDs.insert(tracked.launchID)
            if tracked.value.isRunning {
                tracked.value.terminate()
            }
        }
        processes.removeAll()
        // A process that was cancelled before sign-out may report after the
        // table is cleared. Do not let that old launch mark a later child as
        // cancelled if the operating system reuses its PID.
        cancelledLaunchIDs.removeAll()
    }

    /// Stops one child launched by `start`. The termination callback remains
    /// authoritative: callers still receive its final output and can clean up
    /// a provider machine that was created just before cancellation.
    func cancel(processID: Int32) {
        guard let tracked = processes.entry(processID: processID) else { return }
        cancel(processID: processID, launchID: tracked.launchID)
    }

    /// Cancels only the launch identified by both its PID and unique token. The
    /// token prevents a stale cancellation handle from acting on a later child
    /// after the operating system recycles the PID.
    private func cancel(processID: Int32, launchID: UUID) {
        guard let tracked = processes.entry(processID: processID), tracked.launchID == launchID else { return }
        cancelledLaunchIDs.insert(launchID)
        if tracked.value.isRunning {
            tracked.value.terminate()
        }
    }

    /// Best-effort cleanup for a machine that was announced by a cancelled
    /// create. Delete is idempotent at the socket boundary, so a race with the
    /// create finalizer is safe; the local workspace/catalog cleanup is handled
    /// by the same destroy path as a user-initiated delete. The auth-transition
    /// override keeps a late tombstone from opening a sign-in sheet; the socket
    /// still enforces the account's server-side authorization.
    func destroyMachineBestEffort(_ machineID: String) {
        let id = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        _ = start(
            socketPath: socketPath,
            preferredWindow: nil,
            arguments: ["vm", "rm", id],
            presentsFailureAlert: false,
            allowDuringAuthTransition: true,
            onCompletion: { completion in
                guard completion.succeeded || completion.indicatesCloudVMNotFound else { return }
                AppDelegate.shared?.closeWorkspaces(forManagedCloudVMID: id)
            }
        )
    }

    @discardableResult
    func start(
        socketPath: String,
        preferredWindow: NSWindow?,
        arguments: [String] = ["vm", "base", "open"],
        successTitle: String? = nil,
        presentOutputOnSuccess: Bool = false,
        presentsFailureAlert: Bool = true,
        /// Internal cleanup operations may be delivered after sign-out has
        /// started. They still use the app's authenticated socket path but must
        /// not open a sign-in sheet when the transition has cleared local UI.
        allowDuringAuthTransition: Bool = false,
        failurePresentation: FailurePresentation? = nil,
        environmentOverrides: [String: String] = [:],
        onCancellationReady: (@MainActor (CancellationHandle) -> Void)? = nil,
        onOutput: (@MainActor (String) -> Void)? = nil,
        onCompletion: ((Completion) -> Void)? = nil
    ) -> Bool {
        let accountFlow = AppDelegate.shared?.auth?.accountFlow
        let authState = CloudVMPanelAuthState.resolve(
            isAuthenticated: accountFlow?.isAuthenticated == true,
            isWorkingOnAuth: accountFlow?.isWorkingOnAuth == true
        )
        if !authState.allowsAuthenticatedOperation, !allowDuringAuthTransition {
            // Keep every native launcher entrypoint aligned with the Machines
            // panel: a signed-out action opens the shared sign-in screen and
            // never starts a child CLI that could create or attach a VM.
            _ = AppDelegate.shared?.performAccountSignInWorkspaceAction(
                preferredWindow: preferredWindow,
                debugSource: "cloudVM.auth"
            )
            return false
        }
        let failure = failurePresentation ?? FailurePresentation.forCommand(arguments)
        let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        guard let cliURL,
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            if presentsFailureAlert {
                presentStartFailure(
                    title: failure.title,
                    summary: String(
                        localized: "command.cloudVM.failed.missingCLI",
                        defaultValue: "The bundled cmux CLI is missing from this app build."
                    ),
                    output: "",
                    action: failure.action,
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
        let outputCollector = ProcessOutputCollector(stdout: outputPipe, stderr: errorPipe) { chunk in
            guard let chunk = String(data: chunk, encoding: .utf8), !chunk.isEmpty else { return }
            Task { @MainActor in
                onOutput?(chunk)
            }
        }
        outputCollector.start()
        let launchWindow = preferredWindow
        let launchID = UUID()
        process.terminationHandler = { terminatedProcess in
            let output = outputCollector.finish()
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                // A PID can be reused before this deferred main-actor callback
                // runs. Remove the table entry only when it is still this
                // launch; the old completion must never tear down a new child.
                _ = Self.shared.processes.remove(processID: processIdentifier, launchID: launchID)
                let suppressPresentation = Self.shared.authTransitionSuppressedLaunchIDs.remove(launchID) != nil
                let wasCancelled = Self.shared.cancelledLaunchIDs.remove(launchID) != nil
                let completion = Completion(
                    terminationStatus: terminationStatus,
                    output: output,
                    workspaceId: Self.createdWorkspaceId(from: output),
                    machineId: Self.createdMachineId(from: output),
                    wasCancelled: wasCancelled
                )
                onCompletion?(completion)
                if terminationStatus == 0, presentOutputOnSuccess, !Self.shared.isShuttingDown, !suppressPresentation, !wasCancelled {
                    Self.shared.presentCommandResult(
                        title: successTitle ?? String(localized: "command.cloudVM.result.title", defaultValue: "Cloud VM"),
                        output: output,
                        preferredWindow: launchWindow
                    )
                }
                guard terminationStatus != 0,
                      !Self.shared.isShuttingDown,
                      !suppressPresentation,
                      !wasCancelled,
                      presentsFailureAlert,
                      !failure.isSilent(completion) else { return }
                let format = String(
                    localized: "command.cloudVM.failed.exit",
                    defaultValue: "The Cloud VM command exited with status %d."
                )
                Self.shared.presentStartFailure(
                    title: failure.title,
                    summary: String(format: format, Int(terminationStatus)),
                    output: output,
                    action: failure.action,
                    preferredWindow: launchWindow
                )
            }
        }

        do {
            try process.run()
            let processID = process.processIdentifier
            processes.insert(process, processID: processID, launchID: launchID)
            onCancellationReady?(CancellationHandle { [weak self] in
                self?.cancel(processID: processID, launchID: launchID)
            })
#if DEBUG
            cmuxDebugLog("cloudVM.launch pid=\(processID) socket=\(socketPath)")
#endif
            return true
        } catch {
            outputCollector.cancel()
            if presentsFailureAlert {
                presentStartFailure(
                    title: failure.title,
                    summary: String(
                        localized: "command.cloudVM.failed.launch",
                        defaultValue: "The Cloud VM command could not be launched."
                    ),
                    output: error.localizedDescription,
                    action: failure.action,
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
        let window = Self.presentationWindow(preferred: preferredWindow, key: NSApp.keyWindow, main: NSApp.mainWindow)
        content.apply(to: alert, presentingWindow: window)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    /// `cmux vm new` prints `OK machine=<id>` the moment the machine exists,
    /// before it tries to open it, so a failed open still reports the machine.
    private static func createdMachineId(from output: String) -> String? {
        for token in output.split(whereSeparator: \.isWhitespace) {
            let string = String(token)
            guard string.hasPrefix("machine=") else { continue }
            let id = String(string.dropFirst("machine=".count))
            if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                return id
            }
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

    /// The window a result or failure sheet attaches to, decided when the sheet
    /// is presented, never when the CLI was launched. A launch from a confirm
    /// sheet's completion handler (Delete…, Rename…, Set Up Base) captures that
    /// sheet as the key window; by the time the CLI exits the sheet is gone, and
    /// an alert attached to a dismissed sheet stays on screen when OK is pressed
    /// (only Escape closes it). Such a window is skipped: a live sheet hands over
    /// to its parent, then the key window and the main window are tried, and
    /// with nothing visible the alert runs app-modal instead.
    static func presentationWindow(preferred: NSWindow?, key: NSWindow?, main: NSWindow?) -> NSWindow? {
        for candidate in [preferred, key, main] {
            guard let candidate else { continue }
            if isUsablePresentationWindow(candidate) { return candidate }
            if candidate.isSheet, let parent = candidate.sheetParent, isUsablePresentationWindow(parent) {
                return parent
            }
        }
        return nil
    }

    private static func isUsablePresentationWindow(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isSheet && window.sheetParent == nil && window.attachedSheet == nil
    }

    private func presentStartFailure(title: String, summary: String, output: String, action: String, preferredWindow: NSWindow?) {
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
        alert.messageText = title
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        // House alert style: summary and next steps stay fixed, raw output
        // scrolls, and the sheet is attached to the window so it moves with it.
        let content = safeOutput.isEmpty
            ? CmuxAlertContent(informativeText: informativeText)
            : CmuxAlertContent(flattenedText: informativeText, separatingScrollableDetails: safeOutput)
        let window = Self.presentationWindow(preferred: preferredWindow, key: NSApp.keyWindow, main: NSApp.mainWindow)
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
        onOutput?(data)
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
