import AppKit
import Foundation

extension MenuBarProfilingProgressWindowController {
    @objc func previewAttachment() {
        guard let outputURL else { return }
        packageArchive(profileURL: outputURL, openPreview: true)
    }

    @objc func sendEmail() {
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
        prepareSubmit()
        submitButton.title = String(localized: "statusMenu.profiling.sendingEmail", defaultValue: "Sending...")
        statusLabel.stringValue = String(
            localized: "statusMenu.profiling.sendingEmailStatus",
            defaultValue: "Packaging the profile and sending the email through Mail."
        )

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [submitterURL.path] + MenuBarProfilingProfilePreview.submitArguments(
            profileURL: outputURL,
            email: email,
            note: noteTextView.string,
            send: true
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.finishSubmit(terminationStatus: process.terminationStatus)
            }
        }

        runSubmitProcess(process, outputPipe: nil, errorPipe: errorPipe)
    }

    func packageArchive(profileURL: URL, openPreview: Bool) {
        guard let submitterURL = MenuBarProfilingLauncher.bundledSubmitterURL() else {
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.submitterMissing",
                defaultValue: "The bundled profile submission helper is missing."
            )
            NSSound.beep()
            return
        }

        prepareSubmit()
        openPreviewAfterPackaging = openPreview
        openFolderButton.title = String(localized: "statusMenu.profiling.packagingAttachment", defaultValue: "Packaging...")
        statusLabel.stringValue = String(
            localized: "statusMenu.profiling.packagingAttachmentStatus",
            defaultValue: "Creating the zip attachment for preview."
        )

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [submitterURL.path] + MenuBarProfilingProfilePreview.packageArguments(profileURL: profileURL)
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.finishPackage(terminationStatus: process.terminationStatus)
            }
        }

        runSubmitProcess(process, outputPipe: outputPipe, errorPipe: errorPipe)
    }

    private func prepareSubmit() {
        submitOutput = ""
        submitErrorOutput = ""
        submitButton.isEnabled = false
        openFolderButton.isEnabled = false
    }

    private func runSubmitProcess(_ process: Process, outputPipe: Pipe?, errorPipe: Pipe) {
        do {
            submitProcess = process
            submitOutputPipe = outputPipe
            submitErrorPipe = errorPipe
            try process.run()
        } catch {
            submitProcess = nil
            submitOutputPipe?.fileHandleForReading.readabilityHandler = nil
            submitErrorPipe?.fileHandleForReading.readabilityHandler = nil
            submitOutputPipe = nil
            submitErrorPipe = nil
            submitButton.title = String(localized: "statusMenu.profiling.sendEmail", defaultValue: "Send Email")
            openFolderButton.title = String(localized: "statusMenu.profiling.previewAttachment", defaultValue: "Preview Attachment")
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.submitLaunchFailed",
                defaultValue: "Unable to send the email."
            ) + " " + error.localizedDescription
            updateSubmitState()
            NSSound.beep()
        }
    }

    private func finishPackage(terminationStatus: Int32) {
        drainSubmitPipes()
        clearSubmitProcess()
        openFolderButton.title = String(localized: "statusMenu.profiling.previewAttachment", defaultValue: "Preview Attachment")

        if terminationStatus == 0, let archiveURL = archiveURLFromSubmitOutput() {
            self.archiveURL = archiveURL
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.packageReady",
                defaultValue: "Attachment is ready to preview."
            )
            if openPreviewAfterPackaging {
                previewArchive(archiveURL)
            }
        } else {
            let base = String(
                localized: "statusMenu.profiling.packageFailed",
                defaultValue: "Could not package the attachment."
            )
            statusLabel.stringValue = submitFailureMessage(base: base)
            NSSound.beep()
        }
        openPreviewAfterPackaging = false
        updateAttachmentState()
        updateSubmitState()
    }

    private func finishSubmit(terminationStatus: Int32) {
        drainSubmitPipes()
        clearSubmitProcess()
        submitButton.title = String(localized: "statusMenu.profiling.sendEmail", defaultValue: "Send Email")

        if terminationStatus == 0 {
            statusLabel.stringValue = String(localized: "statusMenu.profiling.emailSent", defaultValue: "Email sent.")
        } else {
            let base = String(localized: "statusMenu.profiling.emailFailed", defaultValue: "The email could not be sent.")
            statusLabel.stringValue = submitFailureMessage(base: base)
            NSSound.beep()
        }
        updateSubmitState()
    }

    private func clearSubmitProcess() {
        submitOutputPipe?.fileHandleForReading.readabilityHandler = nil
        submitErrorPipe?.fileHandleForReading.readabilityHandler = nil
        submitOutputPipe = nil
        submitErrorPipe = nil
        submitProcess = nil
    }

    private func drainSubmitPipes() {
        submitOutputPipe?.fileHandleForReading.readabilityHandler = nil
        submitErrorPipe?.fileHandleForReading.readabilityHandler = nil
        appendRemainingSubmitOutput(from: submitOutputPipe)
        appendRemainingSubmitError(from: submitErrorPipe)
    }

    private func appendRemainingSubmitOutput(from pipe: Pipe?) {
        guard let data = pipe?.fileHandleForReading.readDataToEndOfFile(), !data.isEmpty else {
            return
        }
        if let text = String(data: data, encoding: .utf8) {
            submitOutput += text
        }
    }

    private func appendRemainingSubmitError(from pipe: Pipe?) {
        guard let data = pipe?.fileHandleForReading.readDataToEndOfFile(), !data.isEmpty else {
            return
        }
        if let text = String(data: data, encoding: .utf8) {
            submitErrorOutput += text
        }
    }

    private func archiveURLFromSubmitOutput() -> URL? {
        for line in submitOutput.components(separatedBy: .newlines) {
            guard let range = line.range(of: "Archive: ") else { continue }
            let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func previewArchive(_ archiveURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", archiveURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(archiveURL)
        }
    }

    private func submitFailureMessage(base: String) -> String {
        let tail = submitErrorOutput
            .split(separator: "\n")
            .suffix(2)
            .joined(separator: "\n")
        return tail.isEmpty ? base : base + "\n" + tail
    }
}
