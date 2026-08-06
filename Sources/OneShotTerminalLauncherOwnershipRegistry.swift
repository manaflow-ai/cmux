import Foundation

/// Owns each sensitive launcher until its panel consumes, replaces, or expires it.
@MainActor
final class OneShotTerminalLauncherOwnershipRegistry {
    static let shared = OneShotTerminalLauncherOwnershipRegistry()

    private typealias OwnedLauncher = (
        scriptURL: URL,
        expiryTimer: DispatchSourceTimer
    )

    private var launchersByPanelID: [UUID: OwnedLauncher] = [:]

    func adopt(_ input: PreparedAgentStartupInput?, forPanelID panelID: UUID) {
        guard let scriptURL = input?.launcherScriptURL else { return }
        discard(forPanelID: panelID)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + OneShotTerminalLauncherStore.sensitiveScriptTTL
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.expire(scriptURL: scriptURL, forPanelID: panelID)
            }
        }
        timer.resume()
        launchersByPanelID[panelID] = (
            scriptURL: scriptURL,
            expiryTimer: timer
        )
    }

    func discard(forPanelID panelID: UUID) {
        guard let launcher = launchersByPanelID.removeValue(
            forKey: panelID
        ) else {
            return
        }
        launcher.expiryTimer.setEventHandler {}
        launcher.expiryTimer.cancel()
        try? FileManager.default.removeItem(at: launcher.scriptURL)
    }

    private func expire(scriptURL: URL, forPanelID panelID: UUID) {
        guard launchersByPanelID[panelID]?.scriptURL == scriptURL else {
            return
        }
        discard(forPanelID: panelID)
    }
}
