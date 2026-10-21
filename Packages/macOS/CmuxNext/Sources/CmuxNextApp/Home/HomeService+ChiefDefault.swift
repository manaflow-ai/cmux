import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief

/// The default Chief (#64, 2026-10-21): this Mac's Chief while this Mac's optchat-chief runs,
/// else the Hosted (cloud) Chief. Debug Settings' "Default Chief" (``HomeTunables/chiefDefault``)
/// forces either one. The Chief tab, the page's first conversation and the list's Main all follow it.
extension HomeService {
    /// The default Chief is this Mac's (``HomeChiefDefault/prefersLocal(localRunning:)``).
    ///
    /// The two Chiefs keep two histories. The Hosted Chief got this Mac's history once
    /// (``HostedChiefMigration``, at its first connect); what is said to this Mac's Chief after that
    /// stays on this Mac, and what is said to the Hosted Chief stays in the cloud. A switch either
    /// way shows the other Chief's own history, never a merged one; nothing syncs them.
    var prefersLocalChief: Bool {
        HomeTunables.chiefDefault.value.prefersLocal(localRunning: localChiefRunning)
    }

    /// Whether showing `conversation` (nil: Home itself, a reconnect) starts this Mac's brain host:
    /// never for a cloud Chief's conversation, and for Home itself only while the default Chief
    /// resolves to this Mac's. A host started under the Hosted Chief would turn Auto into this
    /// Mac's Chief at the next Chief tab check (review of #23813).
    func startsLocalBrain(for conversation: String?) -> Bool {
        guard let conversation else { return cloudChief == nil }
        return cloudChiefs.chief(for: conversation) == nil
    }

    /// The brain keeper reports this Mac's host as it starts, exits for good or is shut down
    /// (``ChiefBrainKeeper/onHostChange``), so the default Chief follows without a poll.
    func wireChiefDefault() {
        brain.onHostChange = { [weak self] running in self?.noteLocalChiefHost(running: running) }
    }

    /// This Mac's host runs (or not) now; a change of the default Chief re-runs the Chief tab
    /// check (HomeService.start observes ``prefersLocalChief``).
    func noteLocalChiefHost(running: Bool) {
        if localChiefRunning != running { localChiefRunning = running }
    }

    /// The Chief's conversation the Chief tab and Home's page show first: the default Chief's
    /// (``HomeCloudChiefs/chiefTab(local:localHasHistory:choice:prefersLocal:)``).
    var defaultChiefConversation: String? {
        let local = HomeChiefName.select(from: conversations)
        return tabChiefs.chiefTab(local: local?.id, localHasHistory: (local?.lastSeq ?? 0) > 0, choice: hostedChief.choice,
                                  prefersLocal: prefersLocalChief)
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
