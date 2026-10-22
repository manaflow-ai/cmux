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
    /// (``noteCloudChiefsChecked(for:)``). While this Mac's history is still being copied into the Hosted Chief the
    /// tab shows this Mac's Chief (``tabChiefs``), but the Hosted Chief takes it when the copy settles, so the
    /// cloud Chiefs decide here, not the tab.
    func startsLocalBrain(for conversation: String?) -> Bool {
        if let conversation, cloudChiefs.chief(for: conversation) != nil { return false }
        if prefersLocalChief { return true }
        return !cloudChiefsUnknown && cloudChiefs.shown(choice: hostedChief.choice) == nil
    }

    /// Signed in and the cloud Chiefs not read yet for this account (a failed read counts as not read; a
    /// sign-in or account change makes them unknown again): the Hosted Chief may still take Home.
    var cloudChiefsUnknown: Bool {
        guard let account = currentCloudAccount else { return false }
        return cloudChiefsCheckedAccount != account
    }

    /// The signed-in account's id, or nil when signed out.
    var currentCloudAccount: String? {
        if let cloudAccount { return cloudAccount() }
        let auth = services.cloud.auth
        return auth.isSignedIn ? auth.user?.id : nil
    }

    /// Home opened showing `conversation`: starts this Mac's host when ``startsLocalBrain(for:)`` says so,
    /// else, while the cloud Chiefs are unknown, keeps the ask for ``noteCloudChiefsChecked(for:)``.
    func ensureLocalBrain(asked: Bool, for conversation: String?) {
        if startsLocalBrain(for: conversation) {
            startLocalBrain(asked: asked)
        } else if cloudChiefsUnknown {
            waitingHomeAsk = (waitingHomeAsk ?? false) || asked
        }
    }

    /// A Chief tab check read `account`'s cloud Chiefs (nil: signed out, so there are none): an ask that
    /// waited for them starts this Mac's host only if Home itself now shows this Mac's Chief. A read for an
    /// account that is no longer signed in settles nothing.
    func noteCloudChiefsChecked(for account: String?) {
        guard account == currentCloudAccount else { return }
        if let account {
            guard cloudChiefsCheckedAccount != account else { return }
            cloudChiefsCheckedAccount = account
        }
        guard let asked = waitingHomeAsk else { return }
        waitingHomeAsk = nil
        if startsLocalBrain(for: nil) { startLocalBrain(asked: asked) }
    }

    /// The Chief tab check could not run (`ensure_home` failed, or the daemon has no conversation tabs):
    /// reads whether this Mac's optchat-chief runs and the cloud Chiefs anyway, so the default Chief is
    /// right and an ask that waits for the cloud Chiefs settles. A failed read keeps it waiting for the next check.
    func settleCloudChiefsWithoutTab() async {
        await refreshLocalChiefRunning()
        let account = currentCloudAccount
        // Known already (or signed out since the ask): only a waiting ask settles.
        guard cloudChiefsUnknown else { noteCloudChiefsChecked(for: account); return }
        guard let read = await readCloudChiefs() else { return }
        setCloudChiefs(read)
        noteCloudChiefsChecked(for: account)
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
