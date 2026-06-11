import AppKit
import Foundation

enum PreferredEditorSettings {
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
            line: url.path
        ) {
            return
        }

        guard let command = resolvedCommand() else {
            NSWorkspace.shared.open(url)
            return
        }
        let path = url.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(shellQuote(path))"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Check exit status on a background thread; fall back on failure
            // (e.g. command not found exits 127 but /bin/sh itself succeeds)
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            }
        } catch {
            NSWorkspace.shared.open(url)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
