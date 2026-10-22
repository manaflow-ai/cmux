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

    /// Whether showing `conversation` (nil: Home itself, a reconnect) starts this Mac's brain host ahead of a
    /// message: never for a cloud Chief's conversation, and otherwise only while no cloud Chief is known to
    /// take Home or the default Chief resolves to this Mac's. A host started under the Hosted Chief would turn
    /// Auto into this Mac's Chief at the next Chief tab check (review of #23813), so under the Hosted Chief
    /// even this Mac's Chief, shown, starts none; a person's message to it does (``ChiefBrainKeeper/ask(after:in:)``).
    ///
    /// Signed in, before the first Chief tab check read the cloud Chiefs, Home shows this Mac's Chief only
    /// because the Hosted Chief is not known yet: no host starts then, and the check asks again once it knows
    /// (``noteCloudChiefsChecked()``). While this Mac's history is still being copied into the Hosted Chief the
    /// tab shows this Mac's Chief (``tabChiefs``), but the Hosted Chief takes it when the copy settles, so the
    /// cloud Chiefs decide here, not the tab.
    func startsLocalBrain(for conversation: String?) -> Bool {
        if let conversation, cloudChiefs.chief(for: conversation) != nil { return false }
        if prefersLocalChief { return true }
        return !cloudChiefsUnknown && cloudChiefs.shown(choice: hostedChief.choice) == nil
    }

    /// Signed in and the cloud Chiefs not read yet this launch (a failed read counts as not read): the
    /// Hosted Chief may still take Home.
    var cloudChiefsUnknown: Bool {
        !cloudChiefsChecked && (signedInToCloud?() ?? services.cloud.auth.isSignedIn)
    }

    /// Home opened showing `conversation`: starts this Mac's host when ``startsLocalBrain(for:)`` says so,
    /// else, while the cloud Chiefs are unknown, keeps the ask for ``noteCloudChiefsChecked()``.
    func ensureLocalBrain(asked: Bool, for conversation: String?) {
        if startsLocalBrain(for: conversation) {
            startLocalBrain(asked: asked)
        } else if cloudChiefsUnknown {
            waitingHomeAsk = (waitingHomeAsk ?? false) || asked
        }
    }

    /// The first Chief tab check knows the cloud Chiefs: an ask that waited for it starts this Mac's host
    /// only if Home itself now shows this Mac's Chief.
    func noteCloudChiefsChecked() {
        guard !cloudChiefsChecked else { return }
        cloudChiefsChecked = true
        guard let asked = waitingHomeAsk else { return }
        waitingHomeAsk = nil
        if startsLocalBrain(for: nil) { startLocalBrain(asked: asked) }
    }

    /// `ensure_home` failed before the Chief tab check read the cloud Chiefs: reads them anyway, so an
    /// ask that waits for them settles. A failed read keeps it waiting for the next check.
    func settleCloudChiefsWithoutTab() async {
        guard !cloudChiefsChecked, let read = await readCloudChiefs() else { return }
        setCloudChiefs(read)
        noteCloudChiefsChecked()
    }

    private func startLocalBrain(asked: Bool) {
        if let startsBrain { startsBrain(asked) } else { brain.ensure(asked: asked) }
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
