import Foundation

/// Owns each sensitive launcher until its panel consumes, replaces, or expires it.
@MainActor
final class OneShotTerminalLauncherOwnershipRegistry {
    private typealias OwnedLauncher = (
        scriptURL: URL,
        expiryTimer: DispatchSourceTimer
    )

    private let fileManager: FileManager
    private let sensitiveScriptTTL: TimeInterval
    private let makeExpiryTimer: () -> DispatchSourceTimer
    private var launchersByPanelID: [UUID: OwnedLauncher] = [:]

    init(
        fileManager: FileManager = .default,
        sensitiveScriptTTL: TimeInterval = OneShotTerminalLauncherStore.sensitiveScriptTTL,
        makeExpiryTimer: @escaping () -> DispatchSourceTimer = {
            DispatchSource.makeTimerSource(queue: .main)
        }
    ) {
        self.fileManager = fileManager
        self.sensitiveScriptTTL = sensitiveScriptTTL
        self.makeExpiryTimer = makeExpiryTimer
    }

    func adopt(_ input: PreparedAgentStartupInput?, forPanelID panelID: UUID) {
        guard let scriptURL = input?.launcherScriptURL else { return }
        discard(forPanelID: panelID)

        let timer = makeExpiryTimer()
        timer.schedule(
            deadline: .now() + sensitiveScriptTTL
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
        try? fileManager.removeItem(at: launcher.scriptURL)
    }

    func discardAll() {
        for panelID in Array(launchersByPanelID.keys) {
            discard(forPanelID: panelID)
        }
    }

    private func expire(scriptURL: URL, forPanelID panelID: UUID) {
        guard launchersByPanelID[panelID]?.scriptURL == scriptURL else {
            return
        }
        discard(forPanelID: panelID)
    }

    deinit {
        MainActor.assumeIsolated {
            discardAll()
        }
    }
}
