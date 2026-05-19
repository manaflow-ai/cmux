import Foundation

extension CMUXCLI {
    func installManifestExtension(
        checkoutURL: URL,
        manifest: CmuxUseManifest
    ) throws -> CmuxUseCheckoutResult {
        let fm = FileManager.default
        let installURL = try CmuxUseSupport.manifestInstallURL(for: manifest)
        let parentURL = installURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)

        let existed = fm.fileExists(atPath: installURL.path)
        let tempURL = parentURL.appendingPathComponent(".\(manifest.version).tmp.\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempURL) }

        try fm.copyItem(at: checkoutURL, to: tempURL)
        try? fm.removeItem(at: tempURL.appendingPathComponent(".git", isDirectory: true))

        var backupURLToFinalize: URL?
        var shouldFinalizeBackup = true
        defer {
            if shouldFinalizeBackup, let backupURL = backupURLToFinalize {
                if fm.fileExists(atPath: installURL.path) {
                    try? fm.removeItem(at: backupURL)
                } else if fm.fileExists(atPath: backupURL.path) {
                    try? fm.moveItem(at: backupURL, to: installURL)
                }
            }
        }

        if existed {
            let backupURL = parentURL.appendingPathComponent(".\(manifest.version).previous.\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: installURL, to: backupURL)
            backupURLToFinalize = backupURL
            do {
                try fm.moveItem(at: tempURL, to: installURL)
            } catch {
                let installError = error
                if !fm.fileExists(atPath: installURL.path),
                   fm.fileExists(atPath: backupURL.path) {
                    do {
                        try fm.moveItem(at: backupURL, to: installURL)
                    } catch {
                        shouldFinalizeBackup = false
                        let message = String(
                            localized: "cli.use.error.replaceRestoreFailed",
                            defaultValue: "Failed to replace extension at \(installURL.path): \(installError.localizedDescription). Previous installation remains at \(backupURL.path) because restore failed: \(error.localizedDescription)"
                        )
                        throw CLIError(message: message)
                    }
                }
                throw installError
            }
        } else {
            try fm.moveItem(at: tempURL, to: installURL)
        }
        return CmuxUseCheckoutResult(
            url: installURL,
            action: existed ? "reinstalled" : "installed"
        )
    }

    func runUseInstallCommand(_ command: String, cwd: URL, jsonOutput: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd

        process.standardOutput = jsonOutput ? FileHandle.standardError : FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError(message: String(
                localized: "cli.use.error.installCommandFailed",
                defaultValue: "cmux use install command failed: exit \(process.terminationStatus)"
            ))
        }
    }

    func writeUseLaunchCommandScript(_ command: String) throws -> CmuxUseLaunchScript {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.use.error.emptyLaunchCommand",
                defaultValue: "cmux use launch command is empty"
            ))
        }

        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-use-launch-\(UUID().uuidString.lowercased()).sh",
            isDirectory: false
        )
        let encodedCommand = shellQuote(Data(trimmedCommand.utf8).base64EncodedString())
        let decodeFailureMessage = shellQuote(String(
            localized: "cli.use.launchScript.decodeFailed",
            defaultValue: "\n[cmux] failed to decode launch command; starting a shell.\n"
        ))
        let exitStatusMessage = shellQuote(String(
            localized: "cli.use.launchScript.commandExited",
            defaultValue: "\n[cmux] command exited with status %s; starting a shell.\n"
        ))
        let script = """
        #!/bin/sh
        if ! cmux_use_command="$(printf %s \(encodedCommand) | base64 -d 2>/dev/null || printf %s \(encodedCommand) | base64 -D 2>/dev/null)"; then
          printf %s \(decodeFailureMessage) >&2 || true
          rm -f -- "$0" 2>/dev/null || true
          exec "${SHELL:-/bin/zsh}" -l
        fi
        rm -f -- "$0" 2>/dev/null || true
        /bin/zsh -lc "$cmux_use_command"
        cmux_use_status=$?
        printf \(exitStatusMessage) "$cmux_use_status" >&2 || true
        unset cmux_use_command cmux_use_status
        exec "${SHELL:-/bin/zsh}" -l
        """
        try script.appending("\n").write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return CmuxUseLaunchScript(initialCommand: shellQuote(scriptURL.path), url: scriptURL)
    }
}
