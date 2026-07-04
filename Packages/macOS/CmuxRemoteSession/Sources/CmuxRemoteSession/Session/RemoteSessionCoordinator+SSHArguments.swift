internal import CmuxFoundation
internal import Foundation

// Per-exec SSH argument composition and subprocess error-line selection.
// Faithful lift; argument text is wire/process behavior, do not alter
// without a pinned-behavior reason. (The configuration's own batch builders
// in CmuxCore cover the daemon-transport argv; these compose the
// coordinator's general exec argv, including the non-batch and
// drop-ControlPath variants the batch builders do not have.)
extension RemoteSessionCoordinator {
    func sshCommonArguments(batchMode: Bool, dropControlPath: Bool = false) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return backgroundSSHOptions(configuration.sshOptions, dropControlPath: dropControlPath)
            }
            return normalizedSSHOptions(configuration.sshOptions)
        }()
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if batchMode {
            args += ["-o", "BatchMode=yes"]
            args += ["-o", "ControlMaster=no"]
            // Batch execs append their own positional remote command, which
            // OpenSSH refuses while a host-configured RemoteCommand is in
            // effect (issue #7246); pin RequestTTY=no so a host `RequestTTY
            // force` cannot CRLF-corrupt parsed pipes. Placed before the
            // configuration's options: OpenSSH honors the first value per
            // option, so these also win over caller-supplied conflicts.
            args += SSHHostConfiguredRemoteCommand.overrideArguments
            args += ["-o", "RequestTTY=no"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let token = sshOptionKey(option)
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    func backgroundSSHOptions(_ options: [String], dropControlPath: Bool = false) -> [String] {
        var batchSSHControlOptionKeys: Set<String> = [
            "controlmaster",
            "controlpersist",
        ]
        if dropControlPath {
            batchSSHControlOptionKeys.insert("controlpath")
        }
        return normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }
}
