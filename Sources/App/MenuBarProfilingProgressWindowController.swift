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
    let openFolderButton = NSButton()
    let submitButton = NSButton()
    let closeButton = NSButton()

    private var process: Process?
    private var submitProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var submitErrorPipe: Pipe?
    private var countdownTimer: Timer?
    private var startedAt: Date?
    private var scriptOutput = ""
    private var submitErrorOutput = ""
    private var outputURL: URL?
    private var captureComplete = false

    private var estimatedSeconds: Int {
        MenuBarProfilingLauncher.estimatedCaptureSeconds()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "statusMenu.profiling.title", defaultValue: "Profiling cmux")
        window.isReleasedWhenClosed = false
        super.init(window: window)
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
        if process != nil {
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
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + MenuBarProfilingLauncher.arguments(pid: pid, submitProfile: false)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendScriptOutput(text)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendScriptOutput(text)
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.finish(terminationStatus: process.terminationStatus)
            }
        }

        do {
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
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

        titleLabel.stringValue = String(localized: "statusMenu.profiling.reviewTitle", defaultValue: "Capture a cmux profile")
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        countdownLabel.alignment = .left

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor

        permissionLabel.stringValue = String(
            localized: "statusMenu.profiling.permissionExplanation",
            defaultValue: "macOS may ask for administrator permission because Instruments attaches to the running cmux process and samples its threads. cmux uses that access only to create this diagnostic profile."
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

        openFolderButton.title = String(localized: "statusMenu.profiling.openFolder", defaultValue: "Open Folder")
        openFolderButton.target = self
        openFolderButton.action = #selector(openOutputFolder)

        submitButton.title = String(localized: "statusMenu.profiling.openDraft", defaultValue: "Open Email Draft")
        submitButton.target = self
        submitButton.action = #selector(openEmailDraft)

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
                view: scrollView(for: noteTextView, height: 74)
            ),
            labeledView(
                label: String(localized: "statusMenu.profiling.previewLabel", defaultValue: "Review before sending"),
                view: scrollView(for: previewTextView, height: 170)
            ),
        ])
        reviewStack.orientation = .vertical
        reviewStack.alignment = .leading
        reviewStack.spacing = 8

        let buttonStack = NSStackView(views: [openFolderButton, submitButton, closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        let stack = NSStackView(views: [
            titleLabel,
            countdownLabel,
            detailLabel,
            permissionBox(),
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
        scriptOutput = ""
        submitErrorOutput = ""
        outputURL = nil
        captureComplete = false
        progressIndicator.maxValue = Double(estimatedSeconds)
        progressIndicator.doubleValue = 0
        openFolderButton.isHidden = true
        submitButton.isEnabled = false
        closeButton.isEnabled = true
        emailField.isEnabled = true
        countdownLabel.stringValue = remainingText(estimatedSeconds)
        noteTextView.string = ""
        detailLabel.stringValue = String(
            format: String(
                localized: "statusMenu.profiling.bodyFormat",
                defaultValue: "cmux is running Time Profiler, SwiftUI, Allocations, and System Trace for %d seconds each. Finder stays closed while the capture records. Review the profile before opening the email draft."
            ),
            MenuBarProfilingLauncher.defaultDurationSeconds
        )
        statusLabel.stringValue = String(
            localized: "statusMenu.profiling.starting",
            defaultValue: "Starting Instruments..."
        )
        updatePreview()
        updateSubmitState()
    }

    private func showWindow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
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
        openFolderButton.isHidden = outputURL == nil
        updatePreview()
        updateSubmitState()
    }

    private func finish(terminationStatus: Int32) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        clearReadabilityHandlers()
        process = nil
        progressIndicator.doubleValue = Double(estimatedSeconds)

        if terminationStatus == 0 {
            captureComplete = true
            countdownLabel.stringValue = String(localized: "statusMenu.profiling.completeTitle", defaultValue: "Capture complete")
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.readyToReview",
                defaultValue: "Review the summary and files below, add context, then open the email draft."
            )
        } else {
            countdownLabel.stringValue = String(localized: "statusMenu.profiling.failedTitle", defaultValue: "Profiling failed")
            statusLabel.stringValue = failureMessage()
            NSSound.beep()
        }
        openFolderButton.isHidden = outputURL == nil
        updatePreview()
        updateSubmitState()
    }

    private func finishWithLaunchFailure(_ message: String) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        clearReadabilityHandlers()
        process = nil
        progressIndicator.doubleValue = 0
        countdownLabel.stringValue = String(localized: "statusMenu.profiling.failedTitle", defaultValue: "Profiling failed")
        statusLabel.stringValue = message
        openFolderButton.isHidden = true
        updatePreview()
        updateSubmitState()
        NSSound.beep()
    }

    private func clearReadabilityHandlers() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
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
                defaultValue: "The preview will appear here after the profiler writes the capture folder."
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

    private func summaryText(for outputURL: URL) -> String {
        MenuBarProfilingProfilePreview.summaryText(for: outputURL)
    }

    func updateSubmitState() {
        let validEmail = isValidEmail(trimmedEmailText())
        emailErrorLabel.stringValue = validEmail || emailField.stringValue.isEmpty
            ? ""
            : String(localized: "statusMenu.profiling.invalidEmail", defaultValue: "Enter a valid email address so we can follow up.")
        emailErrorLabel.isHidden = emailErrorLabel.stringValue.isEmpty
        submitButton.isEnabled = captureComplete && outputURL != nil && validEmail && submitProcess == nil
    }

    private func trimmedEmailText() -> String {
        emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    @objc private func openOutputFolder() {
        guard let outputURL else { return }
        NSWorkspace.shared.open(outputURL)
    }

    @objc private func openEmailDraft() {
        guard let outputURL else { return }
        let email = trimmedEmailText()
        guard isValidEmail(email) else {
            updateSubmitState()
            NSSound.beep()
            return
        }
        guard let submitterURL = MenuBarProfilingLauncher.bundledSubmitterURL() else {
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.submitterMissing",
                defaultValue: "The bundled profile submission helper is missing."
            )
            NSSound.beep()
            return
        }

        UserDefaults.standard.set(email, forKey: feedbackSettings.storedEmailKey)
        submitErrorOutput = ""
        submitButton.isEnabled = false
        submitButton.title = String(localized: "statusMenu.profiling.openingDraft", defaultValue: "Opening...")
        statusLabel.stringValue = String(localized: "statusMenu.profiling.openingDraftStatus", defaultValue: "Packaging the profile and opening an email draft.")

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [submitterURL.path] + MenuBarProfilingProfilePreview.submitArguments(
            profileURL: outputURL,
            email: email,
            note: noteTextView.string
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.submitErrorOutput += text
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.finishSubmit(terminationStatus: process.terminationStatus)
            }
        }

        do {
            submitProcess = process
            submitErrorPipe = errorPipe
            try process.run()
        } catch {
            submitProcess = nil
            submitErrorPipe?.fileHandleForReading.readabilityHandler = nil
            submitErrorPipe = nil
            submitButton.title = String(localized: "statusMenu.profiling.openDraft", defaultValue: "Open Email Draft")
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.submitLaunchFailed",
                defaultValue: "Unable to open the email draft."
            ) + " " + error.localizedDescription
            updateSubmitState()
            NSSound.beep()
        }
    }

    private func finishSubmit(terminationStatus: Int32) {
        submitErrorPipe?.fileHandleForReading.readabilityHandler = nil
        submitErrorPipe = nil
        submitProcess = nil
        submitButton.title = String(localized: "statusMenu.profiling.openDraft", defaultValue: "Open Email Draft")

        if terminationStatus == 0 {
            statusLabel.stringValue = String(localized: "statusMenu.profiling.draftOpened", defaultValue: "The email draft is open.")
        } else {
            let base = String(localized: "statusMenu.profiling.draftFailed", defaultValue: "The email draft could not be opened.")
            let tail = submitErrorOutput
                .split(separator: "\n")
                .suffix(2)
                .joined(separator: "\n")
            statusLabel.stringValue = tail.isEmpty ? base : base + "\n" + tail
            NSSound.beep()
        }
        updateSubmitState()
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
