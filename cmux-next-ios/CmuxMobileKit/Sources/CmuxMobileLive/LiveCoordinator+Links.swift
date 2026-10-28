#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileArtifacts
import CmuxMobileBrowserStream
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "live")

/// The links: one per Mac (`MacSession`), each served on its own. Everything
/// a link opens (workspaces, chats, Feed, terminals, files, uploads, pairing)
/// belongs to its Mac, so a second Mac's link never touches the first's.
extension LiveCoordinator {
    // MARK: Session wiring

    /// Connects a new Mac session to the coordinator.
    func wire(_ session: MacSession) {
        session.link.endpoint = { [weak self] macID in
            guard let self, let teamID = self.registeredTeamID else { return nil }
            return LinkEndpoint(baseURL: self.api.baseURL, teamID: teamID, deviceID: self.identity.link, macDeviceID: macID)
        }
        session.link.onLink = { [weak self, weak session] link in
            guard let self, let session else { return }
            self.linkChanged(session, link)
        }
        // Right after each dial, off the main actor: open `auth` then `daemon`
        // (in that order: a Mac that pairs serves channels opened behind
        // `auth`) and send the workspace setup batch.
        let pairing = pairing
        let deviceID = identity.link
        let deviceName = deviceName
        let macID = session.macID
        session.link.prepare = { link, _ in
            await Self.prepareLink(link, pairing: pairing, macID: macID, deviceID: deviceID, deviceName: deviceName)
        }
        session.feed.place = { [weak session] sessionID in session?.place(sessionID: sessionID) }
        session.terminalFeed.request = { [weak session] command, params, connection in
            // Never another connection's (or another Mac's) channel.
            guard let session, session.workspaces.connectionSerial == connection, let client = session.workspaces.daemon else {
                throw LinkError(code: "no-link", message: "Not connected to the Mac")
            }
            var fields: [String: Any] = [:]
            for (key, value) in params { fields[key] = value }
            return try await client.request(command, params: fields)
        }
        session.terminalFeed.type = { [weak session] surface, bytes, connection in
            guard let session, session.workspaces.connectionSerial == connection, let client = session.workspaces.daemon else {
                throw LinkError(code: "no-link", message: "Not connected to the Mac")
            }
            _ = try WorkspaceSync.check(try await client.request("send", params: ["surface": surface, "bytes": bytes.base64EncodedString()]))
        }
        session.workspaces.onTree = { [weak self, weak session] tree in
            guard let self, let session else { return }
            self.apply(tree, session: session)
        }
        session.terminalFeed.send = { [weak session] surface, text, expectForeground, agentSession, connection in
            guard let agentSession else { throw LinkError(code: "no-session", message: "The agent session is not known") }
            // A Feed reply into a terminal agent: this connection's channel only, pasted and
            // submitted in one write, only while that program is still the terminal's foreground
            // one and its agent waits at its prompt in that session (the daemon checks both).
            guard let session, session.workspaces.connectionSerial == connection, let client = session.workspaces.daemon else {
                throw LinkError(code: "no-link", message: "Not connected to the Mac")
            }
            let expectAgent: [String: Any] = ["session": agentSession]
            return try await client.request("send", params: [
                "surface": surface, "text": text, "paste": true, "submit": true,
                "expect_foreground": expectForeground, "expect_agent": expectAgent,
            ])
        }
        session.workspaces.onNotification = { [weak session] post in session?.terminalFeed.notificationPosted(post) }
        session.acpmux.onWatchEvent = { [weak session] event in
            guard let session else { return }
            session.feed.handle(event, sessions: session.acpmux.sessions)
            session.workspaces.setPending(session.acpmux.sessions.mapValues { $0.pendingPermissions > 0 }, waitingFor: session.feed.waitingFor)
        }
        session.creation.capabilities = { [weak self] mac in self?.store.macCapabilities[mac] }
        observe(session)
    }

    private func observe(_ session: MacSession) {
        withObservationTracking {
            _ = session.link.phase
            _ = session.link.media
        } onChange: { [weak self, weak session] in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.sessions[session.macID] === session else { return }
                self.phaseChanged(session)
                self.observe(session)
            }
        }
    }

    /// The session for a Mac id, when it has one.
    func session(macID: String?) -> MacSession? {
        macID.flatMap { sessions[$0] }
    }

    /// The terminal agents' Feed of the Mac `macID` (a Feed item's own Mac; never another's).
    public func terminalFeed(macID: String?) -> TerminalFeed? {
        session(macID: macID)?.terminalFeed
    }

    /// The session of the Mac that shows `tabID`: `macID` when given, else the
    /// focused Mac, else any Mac whose tree lists the tab (tab ids repeat across Macs).
    func session(tabID: String, macID: String?) -> MacSession? {
        if let macID { return sessions[macID] }
        if focused.tree?.surfaces[tabID] != nil || focused.tree?.agentTabs[tabID] != nil { return focused }
        return sessions.values.first { $0.tree?.surfaces[tabID] != nil }
    }

    // MARK: Link

    func linkChanged(_ session: MacSession, _ link: (any MacLink)?) {
        #if DEBUG
        if let link { runNetworkProbeIfAsked(link) }
        #endif
        session.acpmux.macLink = nil
        session.currentLink = link
        session.servedLink = nil
        session.pairingGate = nil
        session.acpmux.approver = nil
        // Pairing belongs to one link (review M1): a banner for another Mac, or a
        // stale "waiting" that holds back the workspaces deadline, never carries over.
        setPairing(.idle, for: session)
        let macID = session.macID
        guard let link else {
            Task {
                await session.workspaces.bind(nil, macID: "")
                await session.acpmux.bind(nil)
            }
            if chiefMacID == macID { chiefOffline() }
            return
        }
        if let prepared = session.link.takePrepared(for: link) as? PreparedLink {
            // The dial already opened `auth` and `daemon`: serve now, in this turn.
            ConnectTimeline.shared.mark("link_served")
            let passed = startServing(session, link, auth: prepared.auth, daemon: prepared.daemon)
            Task { [weak self] in await self?.finishServing(session, link, passed: passed) }
            return
        }
        Task { [weak self] in await self?.serve(session, link) }
    }

    /// What the dial step opened on a link before handing it over
    /// (`LinkController.prepare`): no main-actor turn per channel.
    struct PreparedLink: Sendable {
        let auth: Result<LinkPairing.Opened, LinkError>?
        let daemon: Result<WorkspaceSync.Prepared, LinkError>
    }

    nonisolated static func prepareLink(_ link: any MacLink, pairing: LinkPairing?, macID: String? = nil, deviceID: String,
                                        deviceName: String) async -> PreparedLink {
        let auth = await pairing?.open(link: link, macID: macID)
        ConnectTimeline.shared.mark("pairing_opened")
        do {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            ConnectTimeline.shared.mark("daemon_channel_open")
            return PreparedLink(auth: auth, daemon: .success(await WorkspaceSync.prepare(channel, deviceID: deviceID, deviceName: deviceName)))
        } catch {
            return PreparedLink(auth: auth, daemon: .failure(error as? LinkError ?? LinkError(code: "daemon", message: LinkController.reason(error))))
        }
    }

    /// Pairs `link` and serves its channels. Runs again on the same link from
    /// Retry after the Mac refused or nobody answered (review M2).
    private func serve(_ session: MacSession, _ link: any MacLink) async {
        // Pairing first: a Mac that pairs serves a channel only after `auth`, and holds the
        // ones opened behind it until it passes. Workspaces, the chats and the Feed open
        // right behind it, without waiting for each other (an open costs no round trip).
        ConnectTimeline.shared.mark("link_served")
        let auth = await openPairing(link, macID: session.macID)
        guard let passed = startServing(session, link, auth: auth, daemon: nil) else { return }
        await finishServing(session, link, passed: passed)
    }

    /// Serves `link` from this turn: workspaces bind, the version check and
    /// pairing start. Nil (and `auth` closed) when the link moved on.
    private func startServing(_ session: MacSession, _ link: any MacLink, auth: Result<LinkPairing.Opened, LinkError>?,
                              daemon: Result<WorkspaceSync.Prepared, LinkError>?) -> Task<Bool, Never>? {
        guard session.currentLink === link, sessions[session.macID] === session else {
            if case .success(let opened)? = auth { Task { await opened.close() } }
            if case .success(let prepared)? = daemon { Task { await prepared.client.close() } }
            return nil
        }
        session.servedLink = link
        session.acpmux.macLink = link
        bindWorkspaces(session, link, prepared: daemon)
        Task { [weak self] in await self?.checkVersion(session, link) }
        let passed = startPairing(session, link, auth: auth)
        session.pairingGate = (link, passed)
        return passed
    }

    private func finishServing(_ session: MacSession, _ link: any MacLink, passed: Task<Bool, Never>?) async {
        guard let passed else { return }
        let macID = session.macID
        guard await passed.value else {
            // Nothing on this link is served now: terminals, files and uploads say
            // "not connected" instead of `unpaired`, and Retry pairs again.
            if session.currentLink === link {
                session.servedLink = nil
                session.acpmux.macLink = nil
            }
            return
        }
        // The workspaces deadline waited while the Mac asked its person: start it again.
        if store.macData[macID]?.source != .live { armWorkspacesDeadline(session, link) }
        // Terminal tabs attach lazily (`terminalSession(tabID:)`), each on its
        // own `daemon` channel of this link; open ones reattach now. Input-lane
        // channels may ride another stream, so they wait for pairing here.
        // Only this Mac's terminals are its session's (PR #22555 review: another Mac's
        // would resolve their ids here, get terminal_not_found and end for good).
        session.terminals.removeAll { $0.session == nil }
        let tree = session.workspaces.tree
        for terminal in session.terminals {
            guard let terminalSession = terminal.session,
                  DaemonTerminalSession.shouldReattach(surface: terminalSession.surface, terminalID: terminalSession.terminalID, tree: tree)
            else { continue }
            terminalSession.reconnect()
        }
        // Streamed browser tabs that dropped open again on the focused Mac's link.
        StreamedBrowserDirectory.shared.linkChanged(macID: session.macID)
        do {
            let channel = try await link.openChannel(service: "acpmux", args: [:])
            // The link closed while the channel opened: nothing more on it.
            guard session.currentLink === link else {
                await channel.close(code: "eof", reason: "link replaced")
                return
            }
            await session.acpmux.bind(channel)
            if session.acpmux.isReady { feedStore.syncState = .live }
        } catch {
            log.error("acpmux channel: \(String(describing: error), privacy: .public)")
        }
        guard session.currentLink === link else { return }
        // A failed chat channel is shown, not only logged.
        session.chatsError = session.acpmux.isReady ? nil : (session.acpmux.lastError ?? "chats are unavailable")
        phaseChanged(session)
        if session === focused { await startChief(link) }
    }

    /// `session`'s link once its pairing passed, for channels that may overtake
    /// `auth` (the input lane rides another stream).
    func pairedLink(_ session: MacSession) async throws -> any MacLink {
        guard let link = session.servedLink else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
        if let gate = session.pairingGate, gate.link === link, !(await gate.passed.value) {
            throw LinkError(code: "unpaired", message: "This iPhone is not paired with the Mac")
        }
        guard let current = session.servedLink, current === link else {
            throw LinkError(code: "no-link", message: "Not connected to the Mac")
        }
        return link
    }

    /// The focused Mac's link, for streamed browser tabs (`browser` service).
    public func browserLink() async -> (any BrowserStreamOpening)? {
        focused.servedLink as? any BrowserStreamOpening
    }

    /// A Mac's own link, for its streamed browser tabs (never another Mac's).
    public func browserLink(macID: String) async -> (any BrowserStreamOpening)? {
        guard let session = sessions[macID] else { return nil }
        if session.link.target == nil { touch(macID) }
        return session.servedLink as? any BrowserStreamOpening
    }

    /// Opens the `daemon` channel and loads the workspaces; a failure or a
    /// Mac that never answers shows as a failure with Retry.
    private func bindWorkspaces(_ session: MacSession, _ link: any MacLink, prepared: Result<WorkspaceSync.Prepared, LinkError>? = nil) {
        armWorkspacesDeadline(session, link)
        let macID = session.macID
        Task { [weak self] in
            guard let self else { return }
            do {
                let cached = self.store.workspaces.filter { $0.macID == macID }
                if let prepared {
                    await session.workspaces.bind(try prepared.get(), macID: macID, cached: cached)
                } else {
                    let daemon = try await link.openChannel(service: "daemon", args: [:])
                    ConnectTimeline.shared.mark("daemon_channel_open")
                    await session.workspaces.bind(daemon, macID: macID, cached: cached)
                }
                // The link may have moved on (closed, or this Mac was removed).
                if let error = session.workspaces.lastError, session.currentLink === link, self.store.macData[macID]?.source != .live {
                    self.store.handleMacData(.failed(error), macID: macID)
                }
            } catch {
                log.error("daemon channel: \(String(describing: error), privacy: .public)")
                if session.currentLink === link {
                    self.store.handleMacData(.failed(LinkController.reason(error)), macID: macID)
                }
            }
        }
    }

    /// Fails the workspace list when `link` does not bring it in time.
    private func armWorkspacesDeadline(_ session: MacSession, _ link: any MacLink) {
        session.workspacesTimeout?.cancel()
        let macID = session.macID
        session.workspacesTimeout = Task { [weak self, weak session, clock] in
            do { try await clock.sleep(for: Self.workspacesDeadline) } catch { return }
            guard let self, let session, session.currentLink === link, self.store.macData[macID]?.source != .live else { return }
            // The Mac holds the daemon channel while its person answers "Allow … to connect?"
            // on this link; pairing re-arms the deadline once it passes, and a refusal or
            // timeout fails the channel itself.
            if session.pairingState.isWaiting { return }
            log.error("workspaces did not arrive in time")
            self.store.handleMacData(.failed("the Mac didn't send its workspaces"), macID: macID)
        }
    }

    /// Retry for a Mac (the Workspaces Retry and Reconnect): pairs the link
    /// again when the Mac refused it or nobody answered, reloads the
    /// workspaces on a live link, redials a waiting one, or opens its link.
    public func retry(macID: String) {
        guard let session = sessions[macID], session.link.target != nil else {
            // Its link opens; the focus (banner, Chief) stays where it is.
            touch(macID)
            return
        }
        if session.link.phase.isConnected, let current = session.currentLink, session.servedLink == nil,
           let gate = session.pairingGate, gate.link === current {
            // Review M2: the link is up but its pairing failed. Ask again on it, so an
            // Allow given on the Mac since (or a prompt answered now) takes effect.
            session.pairingGate = nil
            setPairing(.idle, for: session)
            store.handleMacData(.connecting, macID: macID)
            Task { [weak self] in await self?.serve(session, current) }
            return
        }
        if session.link.phase.isConnected, let servedLink = session.servedLink, store.macData[macID]?.source != .live {
            store.handleMacData(.connecting, macID: macID)
            bindWorkspaces(session, servedLink)
        } else {
            session.link.send(.foreground)
        }
    }

    /// Asks the Mac's host which link protocol it speaks. A host that refuses
    /// the `version` service is from before link protocol 2 (control frames
    /// ahead of data, no reader stalls) and drops links under load.
    private func checkVersion(_ session: MacSession, _ link: any MacLink) async {
        let macID = session.macID
        guard let channel = try? await link.openChannel(service: "version", args: [:]) else { return }
        let reply = try? await channel.receive()
        await channel.close(code: "eof", reason: "")
        // Only a host without the service is old; another refusal (`unpaired` while pairing
        // fails) says nothing about its protocol.
        if reply == nil, let closed = channel.closedBy, closed.code != "unknown_service" { return }
        let object = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let protocolVersion = object?["link"] as? Int ?? 1
        let capabilities = Set(object?["capabilities"] as? [String] ?? [])
        if store.macCapabilities[macID] != capabilities { store.macCapabilities[macID] = capabilities }
        log.info("Mac host: \(object?["hostd"] as? String ?? "before 0.2", privacy: .public), link protocol \(protocolVersion, privacy: .public)")
        let outdated = protocolVersion < 2
        guard outdated != session.outdated else { return }
        session.outdated = outdated
        phaseChanged(session)
    }

    /// Opens `auth` on `link` (no round trip); nil without pairing keys.
    private func openPairing(_ link: any MacLink, macID: String) async -> Result<LinkPairing.Opened, LinkError>? {
        guard let pairing else { return nil }
        return await pairing.open(link: link, macID: macID)
    }

    /// The pairing state of a Mac's link; the focused Mac's is the shell's.
    private func setPairing(_ state: LinkPairing.State, for session: MacSession) {
        session.pairingState = state
        if session === focused, pairingState != state { pairingState = state }
    }

    /// Proves this phone's keys on `auth`, starting at once off the main actor
    /// (the Mac holds the `daemon` answers until it passes). The task's value
    /// is false when the Mac refused it.
    private func startPairing(_ session: MacSession, _ link: any MacLink, auth: Result<LinkPairing.Opened, LinkError>?) -> Task<Bool, Never> {
        guard let pairing, let auth else { return Task { true } }
        let name = session.name.isEmpty ? "your Mac" : session.name
        let macID = session.macID
        let keys = pairing.keys
        let onWaiting: @MainActor @Sendable () -> Void = { [weak self, weak session] in
            // Only the current link's pairing speaks for the banner (review M1).
            guard let self, let session, session.currentLink === link else { return }
            // A code for this Mac came in after this link's challenge: a new link presents it.
            if pairing.invites.pending(mac: macID) != nil {
                self.redial(session)
                return
            }
            self.setPairing(keys.takeReplaced() ? .waitingAfterNewKeys(mac: name) : .waiting(mac: name), for: session)
        }
        let outcome = Task.detached { await pairing.finish(auth, macID: macID, onWaiting: onWaiting) }
        return Task { @MainActor [weak self, weak session] in
            let outcome = await outcome.value
            guard let self, let session, session.currentLink === link else { return false }
            switch outcome {
            case .paired(let macDevice):
                self.setPairing(.paired, for: session)
                // Allowed already: a code for this Mac has nothing left to approve.
                pairing.invites.drop(mac: macID)
                session.acpmux.approver = AcpmuxHub.Approver(phoneID: pairing.phoneID, macDevice: macDevice) { reason in
                    try await keys.authorizeApproval(reason: reason)
                }
                return true
            case .legacy:
                self.setPairing(.idle, for: session)
                return true
            case .refused(let error):
                log.error("pairing refused: \(error.code, privacy: .public) \(error.message, privacy: .public)")
                self.setPairing(error.code == "denied" ? .denied(mac: name) : .failed(LinkPairing.refusalText(error)), for: session)
                return false
            }
        }
    }

    /// Settings → Devices → "Remove This iPhone from My Macs": asks every
    /// linked Mac to forget this phone, deletes this account's pairing keys
    /// (so no Mac that approved them can be reached with them again), and
    /// redials, so the next links ask the Macs to allow this iPhone again.
    /// Sign-out does not do this: it keeps the phone's identity and approvals
    /// (verify/persistence.md). One removal at a time (review m4: a second
    /// one racing it would load, and so create, new keys mid-unpair).
    public func removeThisPhoneFromMacs() async {
        guard let pairing, !removalRunning else { return }
        removalRunning = true
        defer { removalRunning = false }
        for session in sessions.values {
            guard let link = session.currentLink else { continue }
            await pairing.unpair(link: link, macID: session.macID)
        }
        // Drop the links the Macs approved with the old keys before they go, so
        // nothing on them loads (and so makes) new keys mid-removal; then dial again.
        let hadLinks = sessions.values.contains { $0.link.target != nil }
        for session in sessions.values { session.link.send(.target(nil)) }
        pairing.keys.reset()
        pairing.push?.reset(user: userID)
        removedFromMacsCount += 1
        if hadLinks { retarget() }
    }

    /// Account deletion, after the service forgot the account: this phone's
    /// keys and device ids for it go too (they can never be used again).
    public func forgetThisPhone() {
        accountDeleted = true
        pairing?.keys.reset()
        pairing?.push?.reset(user: userID)
        pairing?.pins.removeAll()
        DeviceIdentity.forget(userID: userID, store: secrets)
    }

    // MARK: Terminals, files, uploads

    /// A live session for a terminal tab of a Mac (`s<surface>`), or nil
    /// when the tab is not a daemon surface. `macID` names the tab's Mac (tab
    /// ids repeat across Macs); the session opens its channels on that Mac's
    /// link only. Without a link it says so and attaches when the link comes
    /// back (as after any drop).
    public func terminalSession(tabID: String, programName: String, macID: String? = nil) -> DaemonTerminalSession? {
        guard let owner = session(tabID: tabID, macID: macID), let surface = owner.tree?.surfaces[tabID] else { return nil }
        // The daemon titles a shell tab with its folder; the composer says "Send to <program>".
        let program = programName.hasPrefix("/") || programName.hasPrefix("~") || programName.isEmpty ? "terminal" : programName
        let info = ["name": deviceName, "kind": "ios", "device_kind": "iphone", "device_name": deviceName, "device_id": identity.link]
        let terminalID = owner.tree?.terminals[tabID].map { $0.resourceID ?? $0.id }
        let terminal = DaemonTerminalSession(surface: surface, terminalID: terminalID, programName: program, clientInfo: info, open: { [weak owner] in
            guard let link = await owner?.servedLink else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            let channel = try await link.openChannel(service: "daemon", args: [:])
            return DaemonClient(channel: channel)
        }, openInput: { [weak self, weak owner] in
            // Keystrokes ride the link's input lane (PROTOCOL.md "Lanes"), another stream that
            // can overtake `auth`: it opens only once pairing passed (review m6).
            guard let self, let owner else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            let link = try await self.pairedLink(owner)
            let channel = try await link.openInputChannel(service: "daemon", args: [:])
            return DaemonClient(channel: channel)
        })
        terminal.macName = owner.name
        terminal.setMacOffline(owner.link.target == nil || owner.terminalsOffline)
        owner.terminals.removeAll { $0.session == nil }
        owner.terminals.append(MacSession.WeakTerminal(session: terminal))
        // A terminal of a Mac with no link (idle, or never dialed) opens one.
        if owner.link.target == nil { touch(owner.macID) }
        return terminal
    }

    /// Whether the phone holds (or is opening) a link to the Mac.
    public func isLinked(macID: String) -> Bool {
        sessions[macID]?.link.target != nil
    }

    /// The Macs with a link now.
    public var linkedMacIDs: [String] {
        sessions.values.filter { $0.link.target != nil }.map(\.macID)
    }

    /// Pull to refresh on the Workspaces list: every linked Mac lists again.
    public func refreshWorkspaces() async {
        for session in sessions.values where session.workspaces.daemon != nil {
            await session.workspaces.refresh()
        }
    }

    /// The Mac was used now: its link opens if it was closed, and stays while recent.
    public func touch(_ macID: String) {
        lastShown[macID] = ContinuousClock.now
        applyLinks()
    }

    /// Whether the Mac's tree lists the tab (it would get a live session now).
    public func hasLiveSession(tabID: String, macID: String?) -> Bool {
        session(tabID: tabID, macID: macID)?.tree?.surfaces[tabID] != nil
    }

    /// The Mac's screen of a terminal tab as plain text (`read-screen`, one
    /// short-lived `daemon` channel), for the grid card of a tab not opened
    /// in this launch (D5). Nil without a link or on any failure.
    public func terminalScreenText(tabID: String, macID: String? = nil) async -> String? {
        guard let owner = session(tabID: tabID, macID: macID), let surface = owner.tree?.surfaces[tabID],
              let link = owner.servedLink,
              let channel = try? await link.openChannel(service: "daemon", args: [:]) else { return nil }
        let client = DaemonClient(channel: channel)
        await client.start()
        defer { Task { await client.close() } }
        guard let reply = try? await client.request("read-screen", params: ["surface": surface]),
              let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              object["ok"] as? Bool != false,
              let data = object["data"] as? [String: Any] else { return nil }
        return data["text"] as? String
    }

    /// Files and Links previews for a terminal tab: real files on its Mac over
    /// the `file` service, relative paths resolved against the tab's directory.
    public func terminalArtifactSource(tabID: String, macID: String? = nil) -> any ArtifactSource {
        let owner = session(tabID: tabID, macID: macID)
        return LinkFileArtifactSource(macName: owner?.name ?? "your Mac", baseDirectory: owner?.tree?.directories[tabID]) { [weak owner] in
            await owner?.servedLink
        }
    }

    /// Sends a terminal attachment to the tab's Mac (the `upload` service)
    /// into the tab's folder, next to acpmux's attachments, or the Mac's own
    /// uploads folder when the tab has none; returns the file's path there.
    public func terminalUploader(tabID: String, macID: String? = nil) -> @MainActor (Data, String) async throws -> String {
        { [weak self] data, name in
            guard let self, let owner = self.session(tabID: tabID, macID: macID), let link = owner.servedLink else {
                throw LinkUpload.Failure(code: "offline", message: "the Mac isn't connected")
            }
            let cwd = LinkUpload.folder(owner.tree?.directories[tabID])
            do {
                return try await LinkUpload.upload(data, name: name, cwd: cwd, over: link)
            } catch let failure as LinkUpload.Failure where cwd != nil && (failure.code == "forbidden" || failure.code == "not_found") {
                return try await LinkUpload.upload(data, name: name, cwd: nil, over: link)
            }
        }
    }

    // MARK: Chief

    /// Chief runs on the focused Mac's link: when the focus moves to a Mac
    /// whose link is served, Chief moves with it.
    func chiefFollowsFocus() {
        guard chiefMacID != focusedMacID else { return }
        let owner = focused
        guard let link = owner.servedLink else {
            if chiefMacID != nil { chiefOffline() } else { useChiefCloudCopy(macName: owner.name) }
            return
        }
        Task { [weak self] in
            // Its pairing passes first (a refused link serves nothing).
            if let gate = owner.pairingGate, gate.link === link, !(await gate.passed.value) { return }
            guard let self, self.focused === owner, owner.servedLink === link else { return }
            await self.startChief(link)
        }
    }

    func chiefOffline() {
        chiefMacID = nil
        chiefLink = nil
        guard chiefLive else { return }
        // Live mode never falls back to the mock Chief.
        ChiefSession.shared.use(ChiefOfflineBackend())
        ChiefSession.shared.status = nil
        chiefLive = false
        useChiefCloudCopy(macName: ChiefSession.shared.macName)
    }

    /// With no link to the Mac, Chief reads the Mac's cloud copy and its
    /// messages wait in the cloud for the Mac (a450, logs/iphone-chief-DESIGN.md);
    /// nothing changes when the Mac publishes no copy or a link came back meanwhile.
    func useChiefCloudCopy(macName: String?) {
        // task-owner: one host lookup; ends with the swap or nothing
        Task { [weak self] in
            guard let replica = await ChiefSources.shared.macReplica(named: macName) else { return }
            let session = ChiefSession.shared
            guard let self, self.chiefLink == nil, session.backend is ChiefOfflineBackend else {
                replica.close()
                return
            }
            session.use(replica)
            session.status = ChiefSources.macOfflineReason
        }
    }

    /// Chief on the Mac: its Chief owner over the link's scoped `chief`
    /// channel (cmux-mobile-host). Every failure leaves Chief offline with the
    /// reason; there is no stand-in Chief.
    private func startChief(_ link: any MacLink) async {
        // One Chief per link: focus and serving can both ask for it.
        guard chiefLink != ObjectIdentifier(link as AnyObject) else { return }
        chiefLink = ObjectIdentifier(link as AnyObject)
        let session = ChiefSession.shared
        let owner = focused
        chiefMacID = owner.macID
        chiefStarting = true
        // Every way out ends a Try Again in flight, even one for a link replaced meanwhile.
        defer {
            chiefStarting = false
            session.endReconnect()
        }
        // Try Again on Chief's unavailable bar opens the channel again on this link.
        session.reconnect = { [weak self] in self?.retryChief() }
        session.macName = owner.name
        // A file a Chief message links to previews from this Mac (absolute paths only).
        session.fileSource = LinkFileArtifactSource(macName: owner.name, baseDirectory: nil) { [weak owner] in
            await owner?.servedLink
        }
        // Chief's settings show this Mac's last known model until it answers.
        session.macID = owner.macID
        // A newer link (or another focused Mac) took over while this one was opening: leave it be.
        func current() -> Bool { focused === owner && (owner.currentLink as AnyObject?) === (link as AnyObject) }
        func offline(_ reason: String) {
            guard current() else { return }
            // Try Again may open it on this link again.
            chiefLink = nil
            chiefStatus = reason
            session.status = reason
            if chiefLive || !(session.backend is ChiefOfflineBackend) {
                session.use(ChiefOfflineBackend(reason: reason))
            }
            chiefLive = false
            MacHomeFeed.shared.forget(unless: owner.macID)
            log.info("chief unavailable: \(reason, privacy: .public)")
            useChiefCloudCopy(macName: owner.name)
        }
        do {
            let channel = try await link.openChannel(service: ChiefDaemonBackend.service, args: [:])
            let client = DaemonClient(channel: channel)
            let probe = try await client.request("conversation-list", params: [:])
            let object = try? JSONSerialization.jsonObject(with: probe) as? [String: Any]
            if object?["ok"] as? Bool == false {
                await channel.close(code: "eof", reason: "chief unavailable")
                offline(String(localized: "Chief on this Mac: \(object?["error"] as? String ?? "unavailable")"))
                return
            }
            // Home shows this Mac's Home list (its owner's `home-inbox`), on a channel of its own.
            if current() {
                let macID = owner.macID
                Task { await MacHomeFeed.shared.connect(link: link, macID: macID) }
            }
            let conversations = (object?["data"] as? [String: Any])?["conversations"] as? [[String: Any]] ?? []
            let identity = ChiefIdentity.standard
            let hasChief = conversations.contains { summary in
                let ids = (summary["participants"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                return ids.contains(identity.chiefID) && ids.contains(identity.meID)
            }
            guard hasChief else {
                await channel.close(code: "eof", reason: "chief not started")
                offline(ChiefDaemonBackend.notStarted)
                return
            }
            guard current() else {
                await channel.close(code: "eof", reason: "link replaced")
                if chiefLink == ObjectIdentifier(link as AnyObject) { chiefLink = nil }
                return
            }
            session.status = nil
            // Answers to Chief's questions sign with this phone's key after Face ID.
            session.answerSigner = { [weak self] in self?.chiefAnswerSigner() }
            session.use(ChiefDaemonBackend(client: client))
            chiefLive = true
            chiefStatus = nil
        } catch {
            // An older hostd without the `chief` service closes it as unknown.
            let reason = LinkController.reason(error)
            log.info("chief channel refused: \(reason, privacy: .public)")
            offline(Self.chiefRefusal(reason, macName: owner.name))
        }
    }

    /// Try Again on Chief's unavailable bar: the Chief channel again, on the
    /// focused Mac's link that is up now. Without one, the bar says so.
    func retryChief() {
        // One open at a time: the one running now ends the try.
        guard !chiefStarting else { return }
        guard let link = focused.servedLink else {
            ChiefSession.shared.status = String(localized: "Your Mac isn't connected. Chief comes back when it is.")
            return
        }
        // Try Again opens it again, on the same link too.
        chiefLink = nil
        Task { [weak self] in await self?.startChief(link) }
    }

    /// The bar's sentence for a refused `chief` channel. hostd's own text
    /// ("cmux-tui session chief: No such file or directory") is for the log.
    static func chiefRefusal(_ reason: String, macName: String?) -> String {
        let mac = macName ?? String(localized: "your Mac")
        if reason.contains("unknown_service") || reason.contains("no service chief") {
            return String(localized: "This Mac's cmux is too old for Chief on iPhone. Update cmux on the Mac.")
        }
        // hostd closes the channel when the owner's socket is missing ("daemon channel closed").
        if reason.contains("No such file") || reason.contains("not set up") || reason.contains("Connection refused")
            || reason.contains("channel closed") {
            return String(localized: "Chief isn't running on \(mac). Open cmux on the Mac to start it, then try again.")
        }
        return String(localized: "Chief on \(mac) didn't answer (\(reason)).")
    }

    // MARK: Trees and the Feed

    private func apply(_ tree: DaemonTree, session: MacSession) {
        let macID = session.macID
        guard sessions[macID] === session else { return }
        session.tree = tree
        // A chat opened before its tab had a session (a new chat the Mac
        // started later, or a tab shown from the list before the tree came)
        // was built unbound and cached; rebuild it on the bound session.
        for (key, used) in sourcedSessions where (used.macID == macID || used.macID.isEmpty)
            && tree.agentTabs[used.tabID]?.session != used.session {
            // A store built without its Mac (macID empty) is rebuilt when any Mac's tab changes.
            if used.macID.isEmpty, tree.agentTabs[used.tabID] == nil { continue }
            sourcedSessions[key] = nil
            AgentSessionDirectory.shared.invalidate(id: used.tabID, macID: used.macID)
        }
        store.replaceWorkspaces(macID: macID, with: tree.workspaces)
        store.handleMacData(.received(count: tree.workspaces.count), macID: macID)
        session.fedData = true
        // Streamed browser tabs of workspaces closed on the Mac go: a redial
        // must not open them again (transport-verify-20261019.md defect 7).
        // This phone's pending workspaces keep theirs.
        let liveTabs = sessions.values.reduce(into: Set<String>()) { tabs, other in tabs.formUnion(other.tree?.surfaces.keys ?? [:].keys) }
        StreamedBrowserDirectory.shared.retain(tabs: liveTabs.union(store.workspaces.flatMap { $0.tabs.map(\.id) }))
        ConnectTimeline.shared.mark("workspaces_live", detail: "\(tree.workspaces.count) workspaces")
        scheduleSnapshotSave()
        // History items name their workspace and tab once the tree places their session.
        if session.acpmux.isReady { session.feed.hydrate(Array(session.acpmux.sessions.values)) }
        session.terminalFeed.treeChanged(tree, macID: macID, connection: session.workspaces.connectionSerial)
    }

    /// One write per main-queue turn, however many items a burst changed.
    func scheduleFeedSave(_ archive: FeedArchive) {
        guard !feedSavePending else { return }
        feedSavePending = true
        Task { @MainActor [weak self] in
            guard let self, !stopped else { return }
            feedSavePending = false
            // Encoded and written off the main thread (a save per change dropped frames while scrolling).
            archive.saveInBackground(feedStore.items)
        }
    }

    /// Where an acpmux session lives (acpmux session ids are unique across Macs).
    func place(sessionID: String) -> LiveFeed.Place? {
        if let place = focused.place(sessionID: sessionID) { return place }
        for session in sessions.values where session !== focused {
            if let place = session.place(sessionID: sessionID) { return place }
        }
        return nil
    }

    // MARK: Status and banner (SPEC 7.4)

    /// Feeds a Mac's data and connection state from its link phase.
    private func updateMacState(_ session: MacSession) {
        let macID = session.macID
        guard !macID.isEmpty, sessions[macID] === session else { return }
        switch session.link.phase {
        case .idle:
            // The link closed (idle, or the Mac left the policy): the list on
            // screen is last-known data, quietly (no "Can't connect").
            guard session.fedData || store.macConnection[macID] != nil else { return }
            session.fedData = false
            // An offline Mac stays "offline", not plain last-known data.
            if store.macData[macID]?.link != .offline { store.handleMacData(.disconnected(at: Date()), macID: macID) }
            store.macConnection[macID] = nil
        case .macOffline:
            store.handleMacData(.offline, macID: macID)
            store.macConnection[macID] = nil
        case .connecting:
            if store.macData[macID]?.source == .live { store.handleMacData(.disconnected(at: Date()), macID: macID) }
            store.handleMacData(.connecting, macID: macID)
            if store.macConnection[macID] == nil || store.macConnection[macID] == .connected {
                store.macConnection[macID] = .connecting
            }
        case .connected:
            store.macConnection[macID] = .connected
        case .waiting(_, _, let reason, _):
            store.handleMacData(.failed(reason), macID: macID)
            store.macConnection[macID] = .failed(reason)
        }
        scheduleSnapshotSave()
    }

    /// A Mac's terminal tabs say it is offline once its link has been down
    /// for a bounded time, or at once when presence says so (T-LIFE-13:
    /// offline label ≤ 5 s), never "Reattaching…" for 20 minutes (D4).
    private func updateTerminalsOffline(_ session: MacSession) {
        let phase = session.link.phase
        let now = ContinuousClock.now
        if phase.isConnected || phase == .idle {
            session.linkDownSince = nil
        } else if session.linkDownSince == nil {
            session.linkDownSince = now
        }
        let down = session.linkDownSince.map { now - $0 } ?? .zero
        // A closed (idle) link cannot reattach: its terminals say so until it opens again.
        let offline = phase == .idle || phase.showsTerminalsOffline(notConnectedFor: down)
        session.terminalsOffline = offline
        session.terminals.removeAll { $0.session == nil }
        for terminal in session.terminals { terminal.session?.setMacOffline(offline) }
        session.offlineTask?.cancel()
        session.offlineTask = nil
        guard !offline, session.linkDownSince != nil, down < LinkMachine.Phase.offlineAfter * 2 else { return }
        // Look again when the next bound is reached (a retry or redial, then a first dial's longer one).
        let wait = (down < LinkMachine.Phase.offlineAfter ? LinkMachine.Phase.offlineAfter : LinkMachine.Phase.offlineAfter * 2) - down
        session.offlineTask = Task { [weak self, weak session] in
            guard let clock = self?.clock else { return }
            do { try await clock.sleep(for: wait) } catch { return }
            guard let self, let session else { return }
            self.updateTerminalsOffline(session)
        }
    }

    /// One line per linked Mac for its section header and Settings.
    private func statusLines() -> [String: String] {
        var status: [String: String] = [:]
        for session in sessions.values {
            guard let target = session.link.target,
                  let line = session.link.phase.statusLine(macName: target.name, media: session.link.media) else { continue }
            var parts = [line]
            if session.link.phase.isConnected, let chatsError = session.chatsError { parts.append("Chats: \(chatsError)") }
            if session.outdated { parts.append("Update cmux on this Mac") }
            status[target.macID] = parts.joined(separator: " · ")
        }
        return status
    }

    func phaseChanged(_ session: MacSession) {
        updateMacState(session)
        updateTerminalsOffline(session)
        let status = statusLines()
        if status != store.macLinkStatus { store.macLinkStatus = status }
        // The banner speaks for the focused Mac only: another Mac's link
        // shows in its own section header.
        guard session === focused else { return }
        let phase = session.link.phase
        bannerTask?.cancel()
        let name = session.link.target?.name ?? "Mac"
        switch phase {
        case .idle:
            banner = nil
        case .macOffline:
            banner = .macOffline(name)
        case .connected:
            if everConnected, banner != nil, banner != .connected {
                banner = .connected
                bannerTask = Task { [weak self, clock] in
                    do { try await clock.sleep(for: .milliseconds(1500)) } catch { return }
                    self?.banner = nil
                }
            } else {
                banner = nil
            }
            everConnected = true
            if let macID = session.link.target?.macID { connectedMacIDs.insert(macID) }
        case .connecting(let transport, let attempt):
            // Blips heal silently: the reconnecting banner waits 1.5 s.
            if attempt == 1, !everConnected {
                banner = .connecting(to: "\(name) over \(transport.displayName)")
            } else if banner == nil || banner == .connected {
                bannerTask = Task { [weak self, clock] in
                    do { try await clock.sleep(for: .milliseconds(1500)) } catch { return }
                    self?.banner = .reconnecting(to: name)
                }
            }
        case .waiting(let transport, let attempt, let reason, _):
            banner = Self.waitingBanner(
                macName: name, transport: transport, reason: reason, attempt: attempt,
                wasConnected: session.link.target.map { connectedMacIDs.contains($0.macID) } ?? false,
                relayAvailable: relayAvailable)
        }
    }

    /// Redial attempts after a lost link that still read "Reconnecting"
    /// (about the first half minute of the backoff); later ones say why.
    nonisolated static let reconnectingAttempts = 6

    /// The banner while a redial waits out its backoff. An offline Mac is not
    /// a connection failure. A Mac a link was connected to is being
    /// reconnected (the machine keeps retrying), so a lost link reads
    /// "Reconnecting", not "Can't reach", which reads as giving up, for the
    /// first `reconnectingAttempts` attempts. A Mac never reached, or still
    /// unreachable after those, says so; without TURN neither transport gets
    /// through from another network (WireGuard's backend relay is retired).
    nonisolated static func waitingBanner(macName: String, transport: CmuxMobileTransport.TransportKind, reason: String,
                                          attempt: Int, wasConnected: Bool,
                                          relayAvailable: Bool?) -> ConnectionBannerState {
        if reason == LinkController.reason(LinkError(code: "offline", message: "")) { return .macOffline(macName) }
        if wasConnected, attempt <= reconnectingAttempts { return .reconnecting(to: macName) }
        let relay = relayAvailable == false ? ". Relay (TURN) unavailable" : ""
        return .failed("Can't reach \(macName) over \(transport.displayName)\(relay)")
    }
}

/// The Feed's answers go to the Mac whose agent asked, over that Mac's own
/// link, whichever Mac is chosen: each Mac's `LiveFeed` knows its own asks.
/// A Mac whose link is idle (or still opening) is linked on demand and
/// answered once its chats are ready. Pull to refresh reads every linked Mac.
@MainActor
final class MultiMacFeedActions: FeedActions {
    private weak var coordinator: LiveCoordinator?
    /// The coordinator, for the terminal-question answers (`MultiMacFeedActions+Terminal.swift`).
    var coordinatorForTerminal: LiveCoordinator? { coordinator }
    /// How long an answer waits for its Mac's link and chats to open.
    var linkTimeout: Duration = .seconds(20)

    /// Why an answer could not be sent (shown under the card; the ask stays open).
    struct Unsent: Error, Equatable {
        let message: String
    }

    init(coordinator: LiveCoordinator) {
        self.coordinator = coordinator
    }

    private var feeds: [LiveFeed] {
        guard let coordinator else { return [] }
        return [coordinator.focused.feed] + coordinator.sessions.values.filter { $0 !== coordinator.focused }.map(\.feed)
    }

    /// The Mac `item` came from: its own tag, else the Mac whose feed holds the
    /// ask, else the Mac that lists its workspace. Never the chosen Mac by default.
    func macID(of item: FeedItem) -> String? {
        guard let coordinator else { return nil }
        if let macID = item.macID, !macID.isEmpty { return macID }
        if let owner = coordinator.sessions.values.first(where: { $0.feed.owns(item.id) }) { return owner.macID }
        let macID = coordinator.store.workspace(id: item.workspaceID)?.macID
        return macID?.isEmpty == false ? macID : nil
    }

    /// The feed that answers `item`, on its Mac's ready link: an idle link opens,
    /// and an ask the feed has not read on this link is read again first.
    private func owner(_ item: FeedItem) async throws -> LiveFeed {
        guard let coordinator, let macID = macID(of: item) else {
            throw Unsent(message: FeedStore.notConnectedMessage)
        }
        let name = coordinator.store.teams.flatMap(\.macs).first { $0.id == macID }?.name ?? "your Mac"
        guard coordinator.canLink(macID: macID) else {
            throw Unsent(message: "Only the owner of \(name) can answer from a phone. Nothing was sent.")
        }
        // Opens the Mac's link if it was idle, and keeps it (it is recent now)
        // while the answer goes out.
        coordinator.touch(macID)
        guard let session = coordinator.sessions[macID] else {
            throw Unsent(message: "\(name) is offline. Nothing was sent.")
        }
        guard await session.acpmux.waitUntilReady(timeout: linkTimeout, clock: coordinator.clock) else {
            throw Unsent(message: "Couldn't connect to \(name). Nothing was sent.")
        }
        if !session.feed.owns(item.id) { try await session.feed.refresh() }
        // The Mac no longer has the ask: it was answered on the Mac or elsewhere.
        guard session.feed.owns(item.id) else {
            throw AcpmuxConnection.RPCError(code: 0, message: "no pending permission \(item.id)", reason: nil)
        }
        return session.feed
    }

    /// Reads every linked Mac's Feed. Fails only when no Mac could be read.
    func refresh() async throws {
        let ready = feeds.filter { $0.hub?.isReady == true }
        guard !ready.isEmpty else {
            // Nothing linked: the focused Mac's feed says why (and reads terminal events).
            try await coordinator?.focused.feed.refresh()
            return
        }
        var firstError: (any Error)?
        var refreshed = false
        for feed in ready {
            do {
                try await feed.refresh()
                refreshed = true
            } catch {
                firstError = firstError ?? error
            }
        }
        if !refreshed, let firstError { throw firstError }
    }

    func answer(_ item: FeedItem, question: AgentQuestion, with answer: AgentQuestionAnswer) async throws {
        if item.opensTerminal { return try await terminalOwner(item).answer(item, question: question, with: answer) }
        try await owner(item).answer(item, question: question, with: answer)
    }

    func decline(_ item: FeedItem, question: AgentQuestion) async throws {
        if item.opensTerminal { return try await terminalOwner(item).decline(item, question: question) }
        try await owner(item).decline(item, question: question)
    }

    func respond(_ item: FeedItem, request: ACPPermissionRequest, option: ACPPermissionOption) async throws {
        try await owner(item).respond(item, request: request, option: option)
    }

    func message(for error: any Error) -> String {
        if let unsent = error as? Unsent { return unsent.message }
        if let refused = error as? TerminalFeed.QuestionRefused { return refused.message }
        return AcpmuxSessionSource.message(error)
    }

    func isAlreadyAnswered(_ error: any Error) -> Bool {
        guard let error = error as? AcpmuxConnection.RPCError else { return false }
        return error.message.hasPrefix("no pending permission")
    }
}
#endif
