import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief

/// The default Chief (#64, 2026-10-21): this Mac's Chief while this Mac's optchat-chief runs,
/// else the Hosted (cloud) Chief. Settings > Chief's Engine row (`home.chiefEngine`) forces either
/// one. The Chief tab, the page's first conversation and the list's Main all follow it.
extension HomeService {
    /// The default Chief is this Mac's (``HomeChiefDefault/prefersLocal(localRunning:)``).
    var prefersLocalChief: Bool {
        HomeChiefDefault(setting: services.settings?.snapshot.homeChiefEngine).prefersLocal(localRunning: localChiefRunning)
    }

    /// The Chief's conversation the Chief tab and Home's page show first: the default Chief's
    /// (``HomeCloudChiefs/chiefTab(local:localHasHistory:choice:prefersLocal:)``).
    var defaultChiefConversation: String? {
        let local = HomeChiefName.select(from: conversations)
        return tabChiefs.chiefTab(local: local?.id, localHasHistory: (local?.lastSeq ?? 0) > 0, choice: hostedChief.choice,
                                  prefersLocal: prefersLocalChief)
    }

    /// A change of the Engine row re-runs the Chief tab check. The stream emits only the engine id
    /// (a `String`, so repeats drop), not every cmux.json change that replaces the snapshot.
    func observeChiefEngine() {
        let local = services.machines.local
        // task-owner: lives as long as the service; event-driven (Observation)
        chiefEngineObservation = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] in self?.services.settings?.snapshot.homeChiefEngine }).dropFirst() {
                guard let self, let connection = local.connection,
                      local.supports(DaemonCapabilities.shared.workspaceKind) else { continue }
                ensureHomeWorkspace(connection)
            }
        }
    }

    /// Reads again, off the main actor, whether this Mac's optchat-chief runs (it holds the Chief
    /// home's lock: ``ChiefHostStop/runningHostPID(home:isChiefHost:)``); the Chief tab check runs this first.
    func refreshLocalChiefRunning() async {
        let running = await Self.localChiefRuns(chief.home)
        if localChiefRunning != running { localChiefRunning = running }
    }

    @concurrent nonisolated static func localChiefRuns(_ home: ChiefHome) async -> Bool {
        ChiefHostStop.runningHostPID(home: home) != nil
    }
}
