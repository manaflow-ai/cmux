import CmuxHomeCore
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief

/// Every Chief in the Home list on every host, one tagged Main (Lawrence
/// 2026-10-19: "idk which is main one"; 2026-10-20: "local chiefs and cloud
/// chiefs and mac mini chiefs etc all at the same time").
extension HomeService {
    /// The Home list's Chiefs: all of them, the main one on the host the user picked.
    var chiefRoster: HomeChiefRoster {
        let live = liveChiefRoster
        // Until the cloud Chiefs are read, the last launch's Main and places (HomeService+LaunchList).
        guard !cloudChiefsRead, let last = launchRoster else { return live }
        // With This Mac picked and its Chief listed, that Main is the current answer, not a guess
        // waiting on the cloud read: the last launch's cached cloud Main must not take it back.
        let keepsMain = prefersLocalChief && live.main.map { live.places[$0] == .thisMac } == true
        return live.launching(last: last, keepsMain: keepsMain)
    }

    private var liveChiefRoster: HomeChiefRoster {
        let tab = tabChiefs
        let rows: [InboxRow] = homeStore.rows
        let chiefRows = rows.filter { $0.kind == .chief }
        let cloud = Set(chiefRows.filter { homeStore.summary($0.id)?.owner == .cloud }.map(\.id))
        let localID: String? = HomeChiefName.select(from: conversations)?.id
        let local = localID.map { CmuxHomeCore.ConversationID($0) }
        let hosted = tab.hosted?.mainConversation.map { CmuxHomeCore.ConversationID($0) }
        let placed = tab.placed?.mainConversation.map { CmuxHomeCore.ConversationID($0) }
        return HomeChiefRoster.make(rows: rows, local: local, hosted: hosted, placed: placed, server: serverName(of: tab.placed),
                                    showsPlaced: hostedChief.choice == .placed, cloud: cloud, prefersLocal: prefersLocalChief)
    }

    /// Where `conversation`'s cloud Chief runs and its other host, for the Chief's card.
    func chiefHost(of conversation: String) -> HomeChiefHostLine {
        let tab = tabChiefs
        let server = HomeChiefPlace.server(serverName(of: tab.placed) ?? HomeChiefPlace.cloud.label).label
        var line = HomeChiefHostLine()
        if conversation == tab.hosted?.mainConversation { line.place = HomeEngineStrings.runsInCloud }
        if conversation == tab.placed?.mainConversation { line.place = String(format: HomeEngineStrings.runsOnFormat, server) }
        switch tab.otherHost(of: conversation) {
        case .placed: line.switchTo = server
        case .hosted: line.switchTo = HomeChiefPlace.cloud.label
        case nil: break
        }
        return line
    }

    /// The cloud Chief whose main conversation is `conversation` (``HomeCloudChiefs/placement(of:records:)``).
    func cloudChiefPlacement(of conversation: String) -> (id: String, placed: Bool)? {
        cloudChiefs.placement(of: conversation, records: directory.chiefs)
    }

    /// The paired server's name for a placed Chief (its host id while the server is not paired here).
    func serverName(of chief: CloudChief?) -> String? {
        guard let host = chief?.brainPlace?.host else { return nil }
        return services.machines.servers.first { $0.reach.hostID == host }?.name ?? host
    }

    // MARK: The default Chief
    //
    // The default Chief (#64, 2026-10-21): this Mac's Chief while this Mac's optchat-chief runs,
    // else the Hosted (cloud) Chief. Settings > Chief's Engine row (`home.chiefEngine`) forces
    // either one. The Chief tab, the page's first conversation and the list's Main all follow it.

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
                      local.supports(DaemonCapability.workspaceKind.rawValue) else { continue }
                ensureHomeWorkspace(connection)
            }
        }
    }

    /// The cloud Chiefs' conversations the Engine row excludes. With this Mac's Chief the default,
    /// Home never opens one of these, not even as the page's fallback while this Mac's conversation
    /// is not listed yet: the choice is about where the person's Chief messages go.
    ///
    /// Every cloud-owned Chief row counts, not only the two the last cloud read named: a row the
    /// cache kept from an earlier launch, or a Chief whose placement moved, is in the list before
    /// that read lands and would otherwise be the page's first pick.
    var excludedChiefConversations: Set<String> {
        guard prefersLocalChief else { return [] }
        let cloudRows = homeStore.rows
            .filter { $0.kind == .chief && homeStore.summary($0.id)?.owner == .cloud }
            .map(\.id.rawValue)
        let read = [cloudChiefs.hosted?.mainConversation, cloudChiefs.placed?.mainConversation].compactMap { $0 }
        return Set(cloudRows).union(read)
    }

    /// This Mac's brain host started or died (``ChiefBrainKeeper``): Auto follows it, so the Chief
    /// tab check runs again. Without this, Home opening starts the brain after the check settled on
    /// the Hosted Chief, and Auto would keep opening Hosted for the rest of the launch.
    func localChiefHostChanged() {
        chiefHostChange?.cancel()
        // task-owner: one lock read and tab check per brain start or death
        chiefHostChange = Task { [weak self] in
            guard let self else { return }
            // A newer start or death is already reading: its answer is the current one, never this.
            guard await readLocalChiefRunning(), !Task.isCancelled else { return }
            refreshChiefTab()
        }
    }

    /// Reads again, off the main actor, whether this Mac's optchat-chief runs (it holds the Chief
    /// home's lock: ``ChiefHostStop/runningHostPID(home:isChiefHost:)``); the Chief tab check runs this first.
    func refreshLocalChiefRunning() async {
        _ = await readLocalChiefRunning()
    }

    /// Reads whether this Mac's brain runs, off the main actor, and publishes it only when no later
    /// read has. Two callers read it: a brain that started or died, and the Chief tab check. Either
    /// can suspend across the other's whole read, and the older answer must never land on top of
    /// the newer one, which would leave Auto on the wrong Chief for the rest of the launch.
    /// - Returns: whether this read's answer is the current one.
    @discardableResult
    private func readLocalChiefRunning() async -> Bool {
        chiefRunningReads += 1
        let read = chiefRunningReads
        let running = await Self.localChiefRuns(chief.home)
        guard Self.publishes(read: read, published: chiefRunningPublished) else { return false }
        chiefRunningPublished = read
        if localChiefRunning != running { localChiefRunning = running }
        return true
    }

    /// Whether the read numbered `read` may publish its answer, given that `published` is the
    /// newest read that already has. Only a read newer than that one may: an older read resuming
    /// after it would put a stale answer back.
    static func publishes(read: Int, published: Int) -> Bool { read > published }

    @concurrent nonisolated static func localChiefRuns(_ home: ChiefHome) async -> Bool {
        ChiefHostStop.runningHostPID(home: home) != nil
    }
}
