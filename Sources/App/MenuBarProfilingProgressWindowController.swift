import AppKit
import Foundation

@MainActor
final class MenuBarProfilingProgressWindowController: NSWindowController {
    static let shared = MenuBarProfilingProgressWindowController()

    private let titleLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let openFolderButton = NSButton()
    private let closeButton = NSButton()

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var countdownTimer: Timer?
    private var startedAt: Date?
    private var scriptOutput = ""
    private var outputURL: URL?

    private var estimatedSeconds: Int {
        MenuBarProfilingLauncher.estimatedCaptureSeconds()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 260),
            styleMask: [.titled, .closable],
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
        process.arguments = [scriptURL.path] + MenuBarProfilingLauncher.arguments(pid: pid)
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

        titleLabel.stringValue = String(localized: "statusMenu.profiling.title", defaultValue: "Profiling cmux")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 32, weight: .semibold)
        countdownLabel.alignment = .left

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(estimatedSeconds)
        progressIndicator.controlSize = .regular

        openFolderButton.title = String(localized: "statusMenu.profiling.openFolder", defaultValue: "Open Folder")
        openFolderButton.target = self
        openFolderButton.action = #selector(openOutputFolder)

        closeButton.title = String(localized: "statusMenu.profiling.close", defaultValue: "Close")
        closeButton.target = self
        closeButton.action = #selector(closeWindow)

        let buttonStack = NSStackView(views: [openFolderButton, closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        let stack = NSStackView(views: [
            titleLabel,
            countdownLabel,
            detailLabel,
            progressIndicator,
            statusLabel,
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
        ])
    }

    private func resetInterface() {
        scriptOutput = ""
        outputURL = nil
        progressIndicator.maxValue = Double(estimatedSeconds)
        progressIndicator.doubleValue = 0
        openFolderButton.isHidden = true
        closeButton.isEnabled = true
        countdownLabel.stringValue = remainingText(estimatedSeconds)
        detailLabel.stringValue = String(
            format: String(
                localized: "statusMenu.profiling.bodyFormat",
                defaultValue: "cmux is running Time Profiler, SwiftUI, Allocations, and System Trace for %d seconds each. Finder stays closed while the capture records. When it finishes, cmux opens a submission draft with the profile attached."
            ),
            MenuBarProfilingLauncher.defaultDurationSeconds
        )
        statusLabel.stringValue = String(
            localized: "statusMenu.profiling.starting",
            defaultValue: "Starting Instruments..."
        )
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
    }

    private func finish(terminationStatus: Int32) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        clearReadabilityHandlers()
        process = nil
        progressIndicator.doubleValue = Double(estimatedSeconds)

        if terminationStatus == 0 {
            countdownLabel.stringValue = String(localized: "statusMenu.profiling.completeTitle", defaultValue: "Capture complete")
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.completeBody",
                defaultValue: "The profile archive is ready. cmux is opening the submission draft now."
            )
        } else {
            countdownLabel.stringValue = String(localized: "statusMenu.profiling.failedTitle", defaultValue: "Profiling failed")
            statusLabel.stringValue = failureMessage()
            NSSound.beep()
        }
        openFolderButton.isHidden = outputURL == nil
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

    @objc private func openOutputFolder() {
        guard let outputURL else { return }
        NSWorkspace.shared.open(outputURL)
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
