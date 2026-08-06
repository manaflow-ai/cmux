import Foundation

/// Holds startup text and owns any private launcher script until handoff.
struct PreparedAgentStartupInput: Sendable {
    let text: String
    let launcherScriptURL: URL?

    init(text: String, launcherScriptURL: URL? = nil) {
        self.text = text
        self.launcherScriptURL = launcherScriptURL
    }

    func removeLauncherScript(fileManager: FileManager = .default) {
        guard let launcherScriptURL else { return }
        try? fileManager.removeItem(at: launcherScriptURL)
    }

    func scheduleLauncherScriptRemoval() {
        guard let launcherScriptURL else { return }
        OneShotTerminalLauncherStore.scheduleSensitiveLauncherRemoval(
            at: launcherScriptURL
        )
    }
}
