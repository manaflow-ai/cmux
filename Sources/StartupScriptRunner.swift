import Foundation

/// Manages startup script execution for workspaces created from project configs.
/// Scripts are NOT run during session restore to avoid duplicate execution.
@MainActor
final class StartupScriptRunner {

    /// Default delay before sending script text to the terminal surface (milliseconds).
    private static let defaultDelayMs: Int = 5000

    /// Build environment variables for a workspace's startup script.
    func buildEnvironment(workingDirectory: URL) -> [String: String] {
        ["CMUX_FOLDER": workingDirectory.path]
    }

    /// Whether a startup script should run in this context.
    func shouldRunScript(isRestore: Bool) -> Bool {
        !isRestore
    }

    /// Schedule sending script content to a terminal when the shell prompt is ready.
    /// Uses the workspace's onPromptReady callback for reliable detection.
    /// Falls back to delay-based sending if shell integration isn't available.
    func scheduleScript(content: String, workspace: Workspace, panelId: UUID) {
        let lines = Self.prepareScriptLines(content)
        guard !lines.isEmpty else { return }
        scheduleLines(lines, workspace: workspace, panelId: panelId)
    }

    /// Schedule sending a command to a terminal when the shell prompt is ready.
    func scheduleCommand(_ command: String, workspace: Workspace, panelId: UUID) {
        let lines = Self.prepareScriptLines(command)
        guard !lines.isEmpty else { return }
        scheduleLines(lines, workspace: workspace, panelId: panelId)
    }

    /// Send lines to terminal, waiting for prompt ready signal.
    /// Each line is sent individually followed by \r (Enter).
    private func scheduleLines(_ lines: [String], workspace: Workspace, panelId: UUID) {
        let text = lines.joined(separator: "\n") + "\n"

        let sendOnce: @MainActor () -> Void = { [weak workspace] in
            guard let workspace else { return }
            // Remove callback to prevent any second firing
            workspace.onPromptReady.removeValue(forKey: panelId)
            guard let panel = (workspace.focusedTerminalPanel
                ?? workspace.terminalPanel(for: panelId)) else { return }
            panel.sendInteractiveText(text)
        }

        // Primary: wait for shell to report promptIdle
        workspace.onPromptReady[panelId] = sendOnce

        // Fallback: if promptIdle never fires (no shell integration), send after delay
        let fallbackDelayMs = Self.configuredDelayMs()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(fallbackDelayMs)) { [weak workspace] in
            // Only fire if the callback is still pending (promptIdle never arrived)
            guard let workspace, workspace.onPromptReady[panelId] != nil else { return }
            sendOnce()
        }
    }

    /// Strip shebang, leading blank lines, and comment-only lines from script content.
    /// Returns executable command lines only.
    static func prepareScriptLines(_ content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .drop(while: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trimmed.hasPrefix("#")
            })
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Private

    /// Read startup_script_delay_ms from ~/.config/cmux/settings.yaml if it exists.
    private static func configuredDelayMs() -> Int {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/settings.yaml")
        guard let content = try? String(contentsOf: settingsPath, encoding: .utf8) else {
            return defaultDelayMs
        }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("startup_script_delay_ms:") {
                let valueStr = String(trimmed.dropFirst("startup_script_delay_ms:".count))
                    .trimmingCharacters(in: .whitespaces)
                if let value = Int(valueStr), value > 0 {
                    return value
                }
            }
        }
        return defaultDelayMs
    }
}
