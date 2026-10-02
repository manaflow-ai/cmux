import AppKit
import Darwin
import Foundation

private let submitTimeoutSeconds: TimeInterval = 180

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
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.finishSubmit(terminationStatus: status)
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
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.finishPackage(terminationStatus: status)
            }
        }

        runSubmitProcess(process)
    }

    private func prepareSubmit() {
        submitOutput = ""
        submitErrorOutput = ""
        submitTimedOut = false
        clearPrivateSubmitInputs()
        submitButton.isEnabled = false
        openFolderButton.isEnabled = false
    }

    private func makePrivateSubmitInputs(email: String, note: String) throws -> (replyToFile: URL, noteFile: URL) {
        var createdURLs: [URL] = []
        do {
            let replyToFile = try writePrivateSubmitInput(prefix: "cmux-profile-reply-to", text: email)
            createdURLs.append(replyToFile)
            let noteFile = try writePrivateSubmitInput(prefix: "cmux-profile-note", text: note)
            createdURLs.append(noteFile)
            submitPrivateInputURLs = createdURLs
            return (replyToFile, noteFile)
        } catch {
            for url in createdURLs {
                removeLogFile(url)
            }
            throw error
        }
    }

    private func writePrivateSubmitInput(prefix: String, text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).txt")
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.write(contentsOf: data)
        } catch {
            removeLogFile(url)
            throw error
        }
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
            startSubmitTimeoutTimer(for: process)
        } catch {
            submitProcess = nil
            submitTimeoutTimer?.invalidate()
            submitTimeoutTimer = nil
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

    private func startSubmitTimeoutTimer(for process: Process) {
        let pid = process.processIdentifier
        submitTimeoutTimer?.invalidate()
        submitTimeoutTimer = Timer.scheduledTimer(withTimeInterval: submitTimeoutSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let process = self.submitProcess,
                      process.processIdentifier == pid,
                      process.isRunning
                else {
                    return
                }
                self.submitTimedOut = true
                self.statusLabel.stringValue = String(
                    localized: "statusMenu.profiling.submitTimedOut",
                    defaultValue: "Mail did not finish in time. Stopping the send helper so you can retry."
                )
                process.terminate()
                _ = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let process = self.submitProcess,
                              process.processIdentifier == pid,
                              process.isRunning
                        else {
                            return
                        }
                        _ = kill(pid, SIGKILL)
                    }
                }
            }
        }
    }

    private func finishPackage(terminationStatus: Int32) {
        let didTimeOut = submitTimedOut
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
            statusLabel.stringValue = submitFailureMessage(base: base, timedOut: didTimeOut)
            NSSound.beep()
        }
        submitTimedOut = false
        openPreviewAfterPackaging = false
        updateAttachmentState()
        updateSubmitState()
    }

    private func finishSubmit(terminationStatus: Int32) {
        let didTimeOut = submitTimedOut
        drainSubmitLogs()
        clearSubmitProcess()
        submitButton.title = String(localized: "statusMenu.profiling.sendEmail", defaultValue: "Send Email")

        if terminationStatus == 0 {
            emailSent = true
            statusLabel.stringValue = String(localized: "statusMenu.profiling.emailSent", defaultValue: "Email sent.")
        } else {
            let base = String(localized: "statusMenu.profiling.emailFailed", defaultValue: "The email could not be sent.")
            statusLabel.stringValue = submitFailureMessage(base: base, timedOut: didTimeOut)
            NSSound.beep()
        }
        submitTimedOut = false
        updateSubmitState()
    }

    private func clearSubmitProcess() {
        submitTimeoutTimer?.invalidate()
        submitTimeoutTimer = nil
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

    func clearPrivateSubmitInputs() {
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

    private func submitFailureMessage(base: String, timedOut: Bool) -> String {
        if timedOut {
            return base + "\n" + String(
                localized: "statusMenu.profiling.submitTimedOutRetry",
                defaultValue: "The Mail helper timed out and was stopped. You can try again."
            )
        }
        let tail = submitErrorOutput
            .split(separator: "\n")
            .suffix(2)
            .joined(separator: "\n")
        return tail.isEmpty ? base : base + "\n" + tail
    }
}
