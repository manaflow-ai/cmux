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
        let privateInputs: (replyToFile: URL, noteFile: URL)
        do {
            privateInputs = try makePrivateSubmitInputs(email: email, note: noteTextView.string)
        } catch {
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.submitLaunchFailed",
                defaultValue: "Unable to send the email."
            ) + " " + error.localizedDescription
            updateSubmitState()
            NSSound.beep()
            return
        }
        submitButton.title = String(localized: "statusMenu.profiling.sendingEmail", defaultValue: "Sending...")
        statusLabel.stringValue = String(
            localized: "statusMenu.profiling.sendingEmailStatus",
            defaultValue: "Packaging the profile and sending the email through Mail."
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [submitterURL.path] + MenuBarProfilingProfilePreview.submitArguments(
            profileURL: outputURL,
            replyToFile: privateInputs.replyToFile,
            noteFile: privateInputs.noteFile,
            send: true
        )
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.finishSubmit(terminationStatus: process.terminationStatus)
            }
        }

        runSubmitProcess(process)
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
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [submitterURL.path] + MenuBarProfilingProfilePreview.packageArguments(profileURL: profileURL)
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.finishPackage(terminationStatus: process.terminationStatus)
            }
        }

        runSubmitProcess(process)
    }

    private func prepareSubmit() {
        submitOutput = ""
        submitErrorOutput = ""
        clearPrivateSubmitInputs()
        submitButton.isEnabled = false
        openFolderButton.isEnabled = false
    }

    private func makePrivateSubmitInputs(email: String, note: String) throws -> (replyToFile: URL, noteFile: URL) {
        let replyToFile = try writePrivateSubmitInput(prefix: "cmux-profile-reply-to", text: email)
        let noteFile = try writePrivateSubmitInput(prefix: "cmux-profile-note", text: note)
        submitPrivateInputURLs = [replyToFile, noteFile]
        return (replyToFile, noteFile)
    }

    private func writePrivateSubmitInput(prefix: String, text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).txt")
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func runSubmitProcess(_ process: Process) {
        do {
            let outputLog = try makeTemporaryLogFile(prefix: "cmux-profile-submit-output")
            let errorLog = try makeTemporaryLogFile(prefix: "cmux-profile-submit-error")
            submitOutputLogURL = outputLog.0
            submitOutputLogHandle = outputLog.1
            submitErrorLogURL = errorLog.0
            submitErrorLogHandle = errorLog.1
            process.standardOutput = outputLog.1
            process.standardError = errorLog.1
            submitProcess = process
            try process.run()
        } catch {
            submitProcess = nil
            clearSubmitLogs()
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
        drainSubmitLogs()
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
        drainSubmitLogs()
        clearSubmitProcess()
        submitButton.title = String(localized: "statusMenu.profiling.sendEmail", defaultValue: "Send Email")

        if terminationStatus == 0 {
            emailSent = true
            statusLabel.stringValue = String(localized: "statusMenu.profiling.emailSent", defaultValue: "Email sent.")
        } else {
            let base = String(localized: "statusMenu.profiling.emailFailed", defaultValue: "The email could not be sent.")
            statusLabel.stringValue = submitFailureMessage(base: base)
            NSSound.beep()
        }
        updateSubmitState()
    }

    private func clearSubmitProcess() {
        clearSubmitLogs()
        submitProcess = nil
    }

    private func drainSubmitLogs() {
        submitOutputLogHandle?.closeFile()
        submitErrorLogHandle?.closeFile()
        submitOutputLogHandle = nil
        submitErrorLogHandle = nil
        submitOutput += readLogText(from: submitOutputLogURL)
        submitErrorOutput += readLogText(from: submitErrorLogURL)
    }

    private func clearSubmitLogs() {
        submitOutputLogHandle?.closeFile()
        submitErrorLogHandle?.closeFile()
        submitOutputLogHandle = nil
        submitErrorLogHandle = nil
        removeLogFile(submitOutputLogURL)
        removeLogFile(submitErrorLogURL)
        submitOutputLogURL = nil
        submitErrorLogURL = nil
        clearPrivateSubmitInputs()
    }

    private func clearPrivateSubmitInputs() {
        for url in submitPrivateInputURLs {
            removeLogFile(url)
        }
        submitPrivateInputURLs = []
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
