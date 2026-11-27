import AppKit
import CmuxFeedback
import Foundation

@MainActor
final class MenuBarProfilingProgressWindowController: NSWindowController {
    static let shared = MenuBarProfilingProgressWindowController()

    let feedbackSettings = FeedbackComposerSettings()
    let titleLabel = NSTextField(labelWithString: "")
    let countdownLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let permissionLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let progressIndicator = NSProgressIndicator()
    let emailField = NSTextField()
    let emailErrorLabel = NSTextField(labelWithString: "")
    let noteTextView = NSTextView()
    let previewTextView = NSTextView()
    let attachmentLabel = NSTextField(wrappingLabelWithString: "")
    let openFolderButton = NSButton()
    let submitButton = NSButton()
    let closeButton = NSButton()

    private var process: Process?
    var submitProcess: Process?
    var outputLogURL: URL?
    var errorLogURL: URL?
    var outputLogHandle: FileHandle?
    var errorLogHandle: FileHandle?
    var submitOutputLogURL: URL?
    var submitErrorLogURL: URL?
    var submitOutputLogHandle: FileHandle?
    var submitErrorLogHandle: FileHandle?
    var submitPrivateInputURLs: [URL] = []
    var submitTimeoutTimer: Timer?
    var submitTimedOut = false
    private var countdownTimer: Timer?
    private var startedAt: Date?
    private var scriptOutput = ""
    var submitOutput = ""
    var submitErrorOutput = ""
    var outputURL: URL?
    var archiveURL: URL?
    var captureComplete = false
    var openPreviewAfterPackaging = false
    var emailSent = false

    private var estimatedSeconds: Int {
        MenuBarProfilingLauncher.estimatedCaptureSeconds()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "statusMenu.profiling.title", defaultValue: "Profiling cmux")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startProfiling(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        scriptURL: URL? = MenuBarProfilingLauncher.bundledScriptURL()
    ) {
        if process != nil || submitProcess != nil || (captureComplete && outputURL != nil && !emailSent) {
            showWindow()
            return
        }

        resetInterface()
        showWindow()

        guard let scriptURL else {
            finishWithLaunchFailure(
                String(
                    localized: "statusMenu.profiling.scriptMissing",
                    defaultValue: "The bundled profiling script is missing."
                )
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + MenuBarProfilingLauncher.arguments(pid: pid, submitProfile: false)
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.finish(terminationStatus: status)
            }
        }

        do {
            let outputLog = try makeTemporaryLogFile(prefix: "cmux-profile-output")
            let errorLog = try makeTemporaryLogFile(prefix: "cmux-profile-error")
            outputLogURL = outputLog.0
            outputLogHandle = outputLog.1
            errorLogURL = errorLog.0
            errorLogHandle = errorLog.1
            process.standardOutput = outputLog.1
            process.standardError = errorLog.1
            self.process = process
            startedAt = Date()
            startCountdownTimer()
            try process.run()
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.running",
                defaultValue: "Recording CPU, SwiftUI, memory, and system traces in the background."
            )
        } catch {
            finishWithLaunchFailure(
                String(
                    localized: "statusMenu.profiling.launchFailed",
                    defaultValue: "Unable to start profiling."
                ) + " " + error.localizedDescription
            )
        }
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        titleLabel.stringValue = String(localized: "statusMenu.profiling.reviewTitle", defaultValue: "Send a cmux profile")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        countdownLabel.alignment = .left

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor

        permissionLabel.stringValue = String(
            localized: "statusMenu.profiling.permissionExplanation",
            defaultValue: "macOS may ask for administrator permission because Instruments samples the running cmux process."
        )
        permissionLabel.font = .systemFont(ofSize: 12)
        permissionLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(estimatedSeconds)
        progressIndicator.controlSize = .regular

        configureEmailField()
        configureTextView(noteTextView, editable: true)
        configureTextView(previewTextView, editable: false)

        attachmentLabel.font = .systemFont(ofSize: 12)
        attachmentLabel.textColor = .secondaryLabelColor

        openFolderButton.title = String(localized: "statusMenu.profiling.previewAttachment", defaultValue: "Preview Attachment")
        openFolderButton.target = self
        openFolderButton.action = #selector(previewAttachment)

        submitButton.title = String(localized: "statusMenu.profiling.sendEmail", defaultValue: "Send Email")
        submitButton.target = self
        submitButton.action = #selector(sendEmail)

        closeButton.title = String(localized: "statusMenu.profiling.close", defaultValue: "Close")
        closeButton.target = self
        closeButton.action = #selector(closeWindow)

        let reviewStack = NSStackView(views: [
            labeledView(
                label: String(localized: "statusMenu.profiling.emailLabel", defaultValue: "Your email"),
                view: emailField
            ),
            emailErrorLabel,
            labeledView(
                label: String(localized: "statusMenu.profiling.noteLabel", defaultValue: "Anything else we should know?"),
                view: scrollView(for: noteTextView, height: 56)
            ),
            labeledView(
                label: String(localized: "statusMenu.profiling.previewLabel", defaultValue: "Attachment preview"),
                view: scrollView(for: previewTextView, height: 118)
            ),
            attachmentLabel,
        ])
        reviewStack.orientation = .vertical
        reviewStack.alignment = .width
        reviewStack.spacing = 8

        let buttonStack = NSStackView(views: [openFolderButton, submitButton, closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        let stack = NSStackView(views: [
            titleLabel,
            countdownLabel,
            detailLabel,
            permissionLabel,
            progressIndicator,
            statusLabel,
            reviewStack,
            buttonStack,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reviewStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func resetInterface() {
        clearScriptLogs()
        scriptOutput = ""
        submitOutput = ""
        submitErrorOutput = ""
        outputURL = nil
        archiveURL = nil
        captureComplete = false
        progressIndicator.maxValue = Double(estimatedSeconds)
        emailSent = false
        progressIndicator.doubleValue = 0
        openFolderButton.isHidden = false
        openFolderButton.isEnabled = false
        openFolderButton.title = String(localized: "statusMenu.profiling.previewAttachment", defaultValue: "Preview Attachment")
        submitButton.isEnabled = false
        submitButton.title = String(localized: "statusMenu.profiling.sendEmail", defaultValue: "Send Email")
        closeButton.isEnabled = true
        emailField.isEnabled = true
        countdownLabel.stringValue = remainingText(estimatedSeconds)
        noteTextView.string = ""
        detailLabel.stringValue = String(
            format: String(
                localized: "statusMenu.profiling.bodyFormat",
                defaultValue: "Recording CPU, SwiftUI, memory, and system traces for %d seconds each. Finalizing may take longer."
            ),
            MenuBarProfilingLauncher.defaultDurationSeconds
        )
        statusLabel.stringValue = String(
            localized: "statusMenu.profiling.starting",
            defaultValue: "Starting Instruments..."
        )
        updatePreview()
        updateAttachmentState()
        updateSubmitState()
    }

    private func showWindow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCountdown()
            }
        }
        updateCountdown()
    }

    private func updateCountdown() {
        guard let startedAt else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let remaining = max(estimatedSeconds - elapsed, 0)
        progressIndicator.doubleValue = Double(min(elapsed, estimatedSeconds))
        countdownLabel.stringValue = remaining > 0
            ? remainingText(remaining)
            : String(localized: "statusMenu.profiling.finalizing", defaultValue: "Finalizing traces...")
    }

    private func remainingText(_ seconds: Int) -> String {
        String(
            format: String(
                localized: "statusMenu.profiling.remainingFormat",
                defaultValue: "About %d seconds remaining"
            ),
            seconds
        )
    }

    private func appendScriptOutput(_ text: String) {
        scriptOutput += text
        parseOutputURL(from: text)
    }

    private func parseOutputURL(from text: String) {
        for line in text.components(separatedBy: .newlines) {
            if let range = line.range(of: "cmux profiling capture written to ") {
                let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                outputURL = URL(fileURLWithPath: path)
            } else if let range = line.range(of: "Output: ") {
                let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                outputURL = URL(fileURLWithPath: path)
            }
        }
        updateAttachmentState()
        updatePreview()
        updateSubmitState()
    }

    private func finish(terminationStatus: Int32) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        drainScriptLogs()
        clearScriptLogs()
        process = nil
        progressIndicator.doubleValue = Double(estimatedSeconds)

        if terminationStatus == 0 {
            captureComplete = true
            countdownLabel.stringValue = String(localized: "statusMenu.profiling.completeTitle", defaultValue: "Capture complete")
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.readyToReview",
                defaultValue: "Review the attachment, add context, then send the email."
            )
        } else {
            countdownLabel.stringValue = String(localized: "statusMenu.profiling.failedTitle", defaultValue: "Profiling failed")
            statusLabel.stringValue = failureMessage()
            NSSound.beep()
        }
        updateAttachmentState()
        updatePreview()
        updateSubmitState()
    }

    private func finishWithLaunchFailure(_ message: String) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        clearScriptLogs()
        process = nil
        progressIndicator.doubleValue = 0
        countdownLabel.stringValue = String(localized: "statusMenu.profiling.failedTitle", defaultValue: "Profiling failed")
        statusLabel.stringValue = message
        updateAttachmentState()
        updatePreview()
        updateSubmitState()
        NSSound.beep()
    }

    private func drainScriptLogs() {
        outputLogHandle?.closeFile()
        errorLogHandle?.closeFile()
        outputLogHandle = nil
        errorLogHandle = nil
        scriptOutput = readLogText(from: outputLogURL) + readLogText(from: errorLogURL)
        parseOutputURL(from: scriptOutput)
    }

    private func clearScriptLogs() {
        outputLogHandle?.closeFile()
        errorLogHandle?.closeFile()
        outputLogHandle = nil
        errorLogHandle = nil
        removeLogFile(outputLogURL)
        removeLogFile(errorLogURL)
        outputLogURL = nil
        errorLogURL = nil
    }

    private func failureMessage() -> String {
        let base = String(
            localized: "statusMenu.profiling.failedBody",
            defaultValue: "The capture did not finish. If a folder was created, it may contain partial logs."
        )
        let tail = scriptOutput
            .split(separator: "\n")
            .suffix(2)
            .joined(separator: "\n")
        return tail.isEmpty ? base : base + "\n" + tail
    }

    func updatePreview() {
        guard let outputURL else {
            previewTextView.string = String(
                localized: "statusMenu.profiling.previewWaiting",
                defaultValue: "The attachment preview will appear after the profiler writes the capture folder."
            )
            return
        }

        let summary = summaryText(for: outputURL)
        previewTextView.string = MenuBarProfilingProfilePreview.text(
            outputURL: outputURL,
            email: trimmedEmailText(),
            summary: summary
        )
    }

    func updateAttachmentState() {
        if let archiveURL {
            attachmentLabel.stringValue = String(
                format: String(localized: "statusMenu.profiling.archiveReadyFormat", defaultValue: "Attachment: %@"),
                archiveURL.lastPathComponent
            )
        } else if let outputURL {
            let count = MenuBarProfilingProfilePreview.fileCount(for: outputURL)
            attachmentLabel.stringValue = String(
                format: String(localized: "statusMenu.profiling.attachmentReadyFormat", defaultValue: "%d profiling files will be zipped and attached."),
                count
            )
        } else {
            attachmentLabel.stringValue = String(
                localized: "statusMenu.profiling.attachmentWaiting",
                defaultValue: "Attachment will be ready after capture."
            )
        }
        openFolderButton.isEnabled = captureComplete && outputURL != nil && submitProcess == nil
    }

    private func summaryText(for outputURL: URL) -> String {
        MenuBarProfilingProfilePreview.summaryText(for: outputURL)
    }

    func updateSubmitState() {
        let validEmail = isValidEmail(trimmedEmailText())
        emailErrorLabel.stringValue = validEmail || emailField.stringValue.isEmpty
            ? ""
            : String(localized: "statusMenu.profiling.invalidEmail", defaultValue: "Enter a valid email address so we can follow up.")
        emailErrorLabel.isHidden = emailErrorLabel.stringValue.isEmpty
        submitButton.isEnabled = captureComplete && outputURL != nil && validEmail && submitProcess == nil && !emailSent
        updateAttachmentState()
    }

    func trimmedEmailText() -> String {
        emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func clearCompletedCaptureState() {
        cancelSubmitIfNeeded()
        guard process == nil, submitProcess == nil, captureComplete else { return }
        scriptOutput = ""
        submitOutput = ""
        submitErrorOutput = ""
        outputURL = nil
        archiveURL = nil
        captureComplete = false
        emailSent = false
        clearScriptLogs()
    }

    func cancelSubmitIfNeeded() {
        submitTimeoutTimer?.invalidate()
        submitTimeoutTimer = nil
        guard let submitProcess else {
            clearPrivateSubmitInputs()
            return
        }
        submitTimedOut = false
        if submitProcess.isRunning {
            submitProcess.terminate()
        }
        clearPrivateSubmitInputs()
    }
}

extension MenuBarProfilingProgressWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            MenuBarProfilingProgressWindowController.shared.clearCompletedCaptureState()
        }
    }
}
