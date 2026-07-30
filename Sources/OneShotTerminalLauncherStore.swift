import Foundation
import os

/// Stores one-shot terminal actions in private, self-deleting launcher scripts.
struct OneShotTerminalLauncherStore {
    enum CommandExecution {
        /// Runs post-start input directly in the launcher child, then returns
        /// to the terminal host's already-initialized shell.
        case direct
        /// Preserves the pre-existing startup-command behavior used by restored
        /// terminal tools such as tmux. Local agent resume input never uses it.
        case userLoginShell
    }

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let currentDate: Date
    private let logger: Logger

    private let directoryName = "cmux-r"
    private let scriptTTL: TimeInterval = 24 * 60 * 60
    private let pruneInterval: TimeInterval = 5 * 60
    private let pruneMarkerName = ".last-prune"

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        currentDate: Date = Date()
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.currentDate = currentDate
        logger = Logger(subsystem: "com.cmuxterm.app", category: "OneShotTerminalLauncherStore")
    }

    /// Writes a private action payload and returns its one-shot script.
    func writeLauncherScript(
        command: String,
        workingDirectory: String?,
        execution: CommandExecution = .direct
    ) -> URL? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }

        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        let scriptName = "r" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".zsh"
        let scriptURL = directoryURL.appendingPathComponent(scriptName, isDirectory: false)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldLaunchers(in: directoryURL)

            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if let workingDirectory = normalized(workingDirectory) {
                let quotedDirectory = TerminalStartupShellQuoting.singleQuoted(workingDirectory)
                lines.append("{ cd -- \(quotedDirectory) 2>/dev/null || [ ! -d \(quotedDirectory) ]; } || exit $?")
            }
            switch execution {
            case .direct:
                lines.append(trimmedCommand)
            case .userLoginShell:
                lines.append("[[ -n \"${SHELL:-}\" ]] || exit 127")
                lines.append(
                    "exec \"$SHELL\" -lc \(TerminalStartupShellQuoting.singleQuoted(trimmedCommand))"
                )
            }

            try (lines.joined(separator: "\n") + "\n").write(
                to: scriptURL,
                atomically: true,
                encoding: .utf8
            )
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            try? fileManager.removeItem(at: scriptURL)
            logger.error("Failed to write one-shot terminal launcher: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Returns post-start input whose leading space opts into the shell's
    /// history-ignore-space behavior.
    func writeInvocationInput(
        command: String,
        workingDirectory: String?
    ) -> String? {
        guard let launcherURL = writeLauncherScript(
            command: command,
            workingDirectory: workingDirectory
        ) else {
            return nil
        }
        return " /bin/zsh \(TerminalStartupShellQuoting.singleQuoted(launcherURL.path))\n"
    }

    /// Returns a non-resume startup command that interprets a private launcher script.
    func writeStartupCommand(
        command: String,
        workingDirectory: String?
    ) -> String? {
        guard let launcherURL = writeLauncherScript(
            command: command,
            workingDirectory: workingDirectory,
            execution: .userLoginShell
        ) else {
            return nil
        }
        return "/bin/zsh \(TerminalStartupShellQuoting.singleQuoted(launcherURL.path))"
    }

    private func pruneOldLaunchers(in directoryURL: URL) {
        let markerURL = directoryURL.appendingPathComponent(pruneMarkerName, isDirectory: false)
        if let attributes = try? fileManager.attributesOfItem(atPath: markerURL.path),
           let lastPrunedAt = attributes[.modificationDate] as? Date {
            let elapsed = currentDate.timeIntervalSince(lastPrunedAt)
            if elapsed >= 0, elapsed < pruneInterval {
                return
            }
        }
        guard let URLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = currentDate.addingTimeInterval(-scriptTTL)
        for scriptURL in URLs where scriptURL.pathExtension == "zsh" {
            guard let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: scriptURL)
        }
        do {
            try "".write(to: markerURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [
                    .posixPermissions: 0o600,
                    .modificationDate: currentDate,
                ],
                ofItemAtPath: markerURL.path
            )
        } catch {
            logger.error("Failed to record one-shot launcher pruning: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
