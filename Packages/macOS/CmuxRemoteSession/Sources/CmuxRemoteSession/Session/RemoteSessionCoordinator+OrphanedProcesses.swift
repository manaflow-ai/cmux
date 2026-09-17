internal import CmuxFoundation
internal import Foundation

// Best-effort cleanup of orphaned `ssh` transports (reverse relays and
// cmuxd-remote serve-stdio children reparented to launchd after a crash or
// force-quit) before each connection attempt. Faithful lift; the `ps` parse
// and command classification are pinned by tests.
extension RemoteSessionCoordinator {
    /// Parses `ps -axo pid=,ppid=,command=` output and returns the PIDs of
    /// orphaned (PPID 1) cmux-owned ssh transports for `destination`,
    /// narrowed to `relayPort`/`persistentDaemonSlot` when provided. Public
    /// because the matching predicate is pinned by app tests;
    /// `killOrphanedRemoteSSHProcesses` feeds it live `ps` output.
    public static func orphanedCMUXRemoteSSHPIDs(
        psOutput: String,
        destination: String,
        relayPort: Int? = nil,
        persistentDaemonSlot: String? = nil
    ) -> [Int] {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return [] }
        let trimmedPersistentDaemonSlot = persistentDaemonSlot

        return psOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> Int? in
                guard let parsed = parsePSLine(line) else { return nil }
                guard parsed.ppid == 1 else { return nil }
                guard isOrphanedCMUXRemoteSSHCommand(
                    parsed.command,
                    destination: trimmedDestination,
                    relayPort: relayPort,
                    persistentDaemonSlot: trimmedPersistentDaemonSlot
                ) else {
                    return nil
                }
                return parsed.pid
            }
            .sorted()
    }

    static func killOrphanedRemoteSSHProcesses(
        destination: String,
        relayPort: Int? = nil,
        persistentDaemonSlot: String? = nil
    ) {
        guard let output = captureCommandStandardOutput(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,command="]
        ) else {
            return
        }

        for pid in orphanedCMUXRemoteSSHPIDs(
            psOutput: output,
            destination: destination,
            relayPort: relayPort,
            persistentDaemonSlot: persistentDaemonSlot
        ) {
            _ = Darwin.kill(pid_t(pid), SIGTERM)
        }
    }

    private static func captureCommandStandardOutput(
        executablePath: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: outputData, encoding: .utf8),
                  !output.isEmpty else {
                return nil
            }
            return output
        } catch {
            // Best effort cleanup only.
            return nil
        }
    }

    private static func parsePSLine(_ line: Substring) -> (pid: Int, ppid: Int, command: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let scanner = Scanner(string: trimmed)
        var pidValue: Int = 0
        var ppidValue: Int = 0
        guard scanner.scanInt(&pidValue), scanner.scanInt(&ppidValue) else {
            return nil
        }

        let commandStart = scanner.currentIndex
        let command = String(trimmed[commandStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return (pidValue, ppidValue, command)
    }

    private static func isOrphanedCMUXRemoteSSHCommand(
        _ command: String,
        destination: String,
        relayPort: Int?,
        persistentDaemonSlot: String?
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.hasPrefix("/usr/bin/ssh ") || trimmed.hasPrefix("ssh ") else { return false }
        guard commandContainsDestination(trimmed, destination: destination) else { return false }
        let trimmedPersistentDaemonSlot: String? = {
            guard let persistentDaemonSlot else { return nil }
            let trimmed = persistentDaemonSlot.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        if let relayPort {
            if trimmed.contains(" -N ")
                && trimmed.contains(" -R 127.0.0.1:\(relayPort):127.0.0.1:") {
                return true
            }
            guard let trimmedPersistentDaemonSlot else { return false }
            return isCMUXRemotePersistentDaemonServeStdioCommand(
                trimmed,
                slot: trimmedPersistentDaemonSlot
            )
        }

        if trimmed.contains(" -N ") && trimmed.contains(" -R 127.0.0.1:") {
            return true
        }
        if let trimmedPersistentDaemonSlot {
            if isCMUXRemotePersistentDaemonServeStdioCommand(
                trimmed,
                slot: trimmedPersistentDaemonSlot
            ) {
                return true
            }
            return isCMUXRemoteNonPersistentDaemonServeStdioCommand(trimmed)
        }
        if isCMUXRemoteDaemonServeStdioCommand(trimmed) {
            return true
        }
        return false
    }

    private static func isCMUXRemoteDaemonServeStdioCommand(_ command: String) -> Bool {
        guard command.contains("cmuxd-remote") else { return false }
        let normalized = command
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
        return normalized.contains(" serve ") && normalized.contains(" --stdio")
    }

    private static func isCMUXRemoteNonPersistentDaemonServeStdioCommand(_ command: String) -> Bool {
        guard isCMUXRemoteDaemonServeStdioCommand(command) else { return false }
        let normalized = command
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
        return !normalized.contains(" --persistent")
    }

    private static func isCMUXRemotePersistentDaemonServeStdioCommand(
        _ command: String,
        slot: String
    ) -> Bool {
        guard isCMUXRemoteDaemonServeStdioCommand(command) else { return false }
        let normalized = command
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
        guard normalized.contains(" --persistent") else { return false }
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for index in tokens.indices {
            let token = tokens[index]
            if token == "--slot" {
                return nextNonShellEscapeToken(after: index, in: tokens) == slot
            }
            if token.hasPrefix("--slot=") {
                let slotValue = String(token.dropFirst("--slot=".count))
                if !slotValue.isEmpty {
                    return slotValue == slot
                }
                return nextNonShellEscapeToken(after: index, in: tokens) == slot
            }
        }
        return false
    }

    private static func nextNonShellEscapeToken(after index: Int, in tokens: [String]) -> String? {
        var nextIndex = index + 1
        while tokens.indices.contains(nextIndex) {
            let token = tokens[nextIndex]
            if !isShellEscapeNoiseToken(token) {
                return token
            }
            nextIndex += 1
        }
        return nil
    }

    private static func isShellEscapeNoiseToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0 == "\\" }
    }

    private static func commandContainsDestination(_ command: String, destination: String) -> Bool {
        guard !destination.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: destination)
        guard let regex = try? NSRegularExpression(
            pattern: "(^|[\\s'\\\"])\(escaped)($|[\\s'\\\"])",
            options: []
        ) else {
            return command.contains(destination)
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }
}
