import AppKit
import Foundation
import OSLog

nonisolated private let preferredEditorLogger = Logger(subsystem: "com.cmuxterm.app", category: "PreferredEditor")

enum PreferredEditorSettings {
    /// UserDefaults key backing Settings → App → "Open Files With".
    static let key = "preferredEditorCommand"

    /// Returns the configured editor command, or nil to use system default.
    static func resolvedCommand(defaults: UserDefaults = .standard) -> String? {
        guard let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else {
            return nil
        }
        return stored
    }

    /// Open a file path with the user's preferred editor, falling back to system default.
    static func open(_ url: URL) {
        if CmuxUITestCapture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: url.path(percentEncoded: false)
        ) {
            return
        }

        guard let command = resolvedCommand() else {
            NSWorkspace.shared.open(url)
            return
        }
        let path = url.path(percentEncoded: false)
        // Log only the executable's basename publicly; the full command is
        // free-form shell text that can carry sensitive paths or arguments.
        let commandName = command.split(separator: " ").first
            .map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? "(empty)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(shellQuote(path))"]
        process.environment = launchEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Fall back on failure without blocking a thread for the editor's
        // lifetime (e.g. command not found exits 127 but /bin/sh itself
        // succeeds; a waiting editor like `code -w` can run for hours).
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            preferredEditorLogger.error(
                "preferred editor command \(commandName, privacy: .public) exited \(process.terminationStatus, privacy: .public) for \(path, privacy: .private); falling back to the OS default handler"
            )
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        do {
            try process.run()
        } catch {
            preferredEditorLogger.error(
                "failed to launch preferred editor command \(commandName, privacy: .public): \(error.localizedDescription, privacy: .public); falling back to the OS default handler"
            )
            NSWorkspace.shared.open(url)
        }
    }

    /// Environment for the spawned editor process.
    ///
    /// GUI apps inherit a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`)
    /// that lacks the directories where editor CLIs are typically installed,
    /// so a bare command such as `code` exits 127 even though the same
    /// command works in a terminal (#5817). Append the standard CLI
    /// directories when missing; inherited entries keep precedence.
    static func launchEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        var entries = (base["PATH"] ?? "")
            .split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if entries.isEmpty {
            entries = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        }
        for directory in ["/usr/local/bin", "/opt/homebrew/bin"] where !entries.contains(directory) {
            entries.append(directory)
        }
        environment["PATH"] = entries.joined(separator: ":")
        return environment
    }

    /// Wraps a path in single quotes for safe interpolation into `/bin/sh -c`.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
