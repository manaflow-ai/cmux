import CmuxFoundation
import Foundation

@MainActor
extension RemoteTmuxController {
    @discardableResult
    func attachHost(
        host: RemoteTmuxHost,
        windowTarget: RemoteTmuxAttachWindowTarget,
        activate: Bool
    ) async throws -> RemoteTmuxAttachOutcome {
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        let initialExistingMirrorWindowID = existingMirrorManager(for: host)
            .flatMap { appDelegate.windowId(for: $0) }
        let initialActiveWindowID = appDelegate.tabManager
            .flatMap { appDelegate.windowId(for: $0) }
        if windowTarget != .dedicatedNewWindow {
            guard windowTarget.resolve(
                existingMirrorWindowID: initialExistingMirrorWindowID,
                activeWindowID: initialActiveWindowID,
                isLive: { appDelegate.tabManagerFor(windowId: $0) != nil }
            ) != nil else {
                // Reject a guaranteed-invalid destination before discovery can
                // create a default remote session or open a cached SSH master.
                throw RemoteTmuxError.unreachable("app not ready")
            }
        }
        guard windowRegistry.beginAttach(hostHash: host.connectionHash) else {
            throw RemoteTmuxError.unreachable("already attaching \(host.destination)")
        }
        defer { windowRegistry.endAttach(hostHash: host.connectionHash) }

        let sessions: [RemoteTmuxSession]
        do {
            sessions = try await transport(for: host).discoverMirrorSessions(createIfEmpty: true)
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                return .authRequired(sshArgv: host.interactiveAuthInvocation())
            }
            throw error
        }
        guard !sessions.isEmpty else {
            throw RemoteTmuxError.unreachable("no tmux sessions on \(host.destination)")
        }
        try Task.checkCancellation()
        try await ensureControlMasterReadyForBurst(host: host)

        // Resolve stable ids after every SSH await. Explicit window routing
        // fails closed if that window disappeared; contextual routing may
        // recover to the active window. Dedicated-window requests create their
        // window only after discovery/auth preflight, so failures never leave
        // empty chrome behind.
        let resolvedWindowId: UUID
        let targetManager: TabManager
        let bootstrapWorkspaceId: UUID?
        if windowTarget == .dedicatedNewWindow {
            resolvedWindowId = appDelegate.createMainWindow(shouldActivate: false)
            guard let newWindowManager = appDelegate.tabManagerFor(windowId: resolvedWindowId) else {
                appDelegate.discardMainWindowWithoutClosedHistory(windowId: resolvedWindowId)
                cleanUpTransportAfterFailedMirror(host: host)
                throw RemoteTmuxError.windowCreationFailed
            }
            targetManager = newWindowManager
            bootstrapWorkspaceId = newWindowManager.tabs.first?.id
            moveExistingMirrors(for: host, into: newWindowManager)
        } else {
            // A live existing mirror stays first so one host cannot be split
            // across windows by a contextual or explicit attach.
            let existingMirrorWindowID = existingMirrorManager(for: host)
                .flatMap { appDelegate.windowId(for: $0) }
            let activeWindowID = appDelegate.tabManager
                .flatMap { appDelegate.windowId(for: $0) }
            guard let existingWindowId = windowTarget.resolve(
                existingMirrorWindowID: existingMirrorWindowID,
                activeWindowID: activeWindowID,
                isLive: { appDelegate.tabManagerFor(windowId: $0) != nil }
            ), let existingWindowManager = appDelegate.tabManagerFor(windowId: existingWindowId) else {
                // A valid target can close while SSH discovery is in flight. A new
                // host has no mirror owner to clean up the transport in that race.
                if initialExistingMirrorWindowID == nil {
                    transportRegistry.remove(connectionHash: host.connectionHash)
                    RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
                }
                throw RemoteTmuxError.unreachable("app not ready")
            }
            resolvedWindowId = existingWindowId
            targetManager = existingWindowManager
            bootstrapWorkspaceId = nil
        }

        let workspaceIds = mirrorDiscoveredSessions(host: host, sessions: sessions, into: targetManager)
        guard !workspaceIds.isEmpty else {
            cleanUpTransportAfterFailedMirror(host: host)
            if windowTarget == .dedicatedNewWindow {
                appDelegate.discardMainWindowWithoutClosedHistory(windowId: resolvedWindowId)
            }
            throw RemoteTmuxError.unreachable("could not mirror any tmux session on \(host.destination)")
        }

        if let bootstrapWorkspaceId,
           targetManager.tabs.count > 1,
           let bootstrap = targetManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           !bootstrap.isRemoteTmuxMirror {
            targetManager.closeWorkspace(bootstrap, recordHistory: false)
        }

        if activate {
            selectFirstMirrorWorkspace(for: host, in: targetManager)
            _ = appDelegate.focusMainWindow(windowId: resolvedWindowId)
        }
        return .mirrored(windowId: resolvedWindowId, workspaceIds: workspaceIds)
    }

    @discardableResult
    func mirrorDiscoveredSessions(
        host: RemoteTmuxHost,
        sessions: [RemoteTmuxSession],
        into tabManager: TabManager
    ) -> [UUID] {
        // A mirror whose workspace died without a controller-driven detach
        // must not block re-attach: its stale key makes `mirrorSessions` skip
        // recreation while the dead workspace fails the manager filter below,
        // so every retry would mirror nothing.
        purgeDeadMirrors(for: host)
        // `mirrorSessions` applies stable-session-id de-dup and seeds discovery's
        // ids into new mirrors, so bulk discovery can't duplicate a session
        // mid-rename (#7362, #7365).
        mirrorSessions(sessions, host: host, into: tabManager)
        let managerWorkspaceIds = Set(tabManager.tabs.map(\.id))
        return sessionMirrors.values.compactMap { mirror in
            guard mirror.host.connectionHash == host.connectionHash,
                  let workspaceId = mirror.mirroredWorkspaceId,
                  managerWorkspaceIds.contains(workspaceId) else { return nil }
            return workspaceId
        }
    }

    private func purgeDeadMirrors(for host: RemoteTmuxHost) {
        for (key, mirror) in sessionMirrors
        where mirror.host.connectionHash == host.connectionHash
            && mirror.mirroredWorkspaceId == nil {
            sessionMirrors.removeValue(forKey: key)
            mirror.detachObserver()
        }
    }

    /// After an attach that mirrored nothing: live mirrors in other windows
    /// still share this host's ControlMaster, so tear the transport down only
    /// when nothing live remains on the connection.
    func cleanUpTransportAfterFailedMirror(host: RemoteTmuxHost) {
        let hasLiveMirror = sessionMirrors.values.contains { mirror in
            mirror.host.connectionHash == host.connectionHash
                && mirror.mirroredWorkspaceId != nil
        }
        guard !hasLiveMirror else { return }
        transportRegistry.remove(connectionHash: host.connectionHash)
        RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
    }

    func existingMirrorManager(for host: RemoteTmuxHost) -> TabManager? {
        for mirror in sessionMirrors.values where mirror.host.connectionHash == host.connectionHash {
            guard let workspaceId = mirror.mirroredWorkspaceId,
                  let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { continue }
            return manager
        }
        return nil
    }

    /// Consolidates an existing host mirror into a newly created dedicated window.
    private func moveExistingMirrors(for host: RemoteTmuxHost, into targetManager: TabManager) {
        let hostWorkspaceIds = Set(sessionMirrors.values.compactMap { mirror -> UUID? in
            guard mirror.host.connectionHash == host.connectionHash else { return nil }
            return mirror.mirroredWorkspaceId
        })
        var sourceManagers: [TabManager] = []
        var seenSourceManagers: Set<ObjectIdentifier> = []
        for mirror in sessionMirrors.values where mirror.host.connectionHash == host.connectionHash {
            guard let workspaceId = mirror.mirroredWorkspaceId,
                  let sourceManager = mirror.mirroredWorkspace?.owningTabManager
                    ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  sourceManager !== targetManager,
                  seenSourceManagers.insert(ObjectIdentifier(sourceManager)).inserted else { continue }
            sourceManagers.append(sourceManager)
        }
        for sourceManager in sourceManagers {
            let workspaces = sourceManager.tabs.filter { hostWorkspaceIds.contains($0.id) }
            for workspace in workspaces {
                guard let detached = sourceManager.detachWorkspace(tabId: workspace.id) else { continue }
                targetManager.attachWorkspace(detached, select: false)
            }
        }
    }

    private func selectFirstMirrorWorkspace(for host: RemoteTmuxHost, in tabManager: TabManager) {
        let hostWorkspaceIds = Set(sessionMirrors.values.compactMap { mirror -> UUID? in
            guard mirror.host.connectionHash == host.connectionHash else { return nil }
            return mirror.mirroredWorkspaceId
        })
        guard let workspace = tabManager.tabs.first(where: { hostWorkspaceIds.contains($0.id) }) else { return }
        tabManager.selectWorkspace(workspace)
    }

    /// Surfaces an interactive login for a mirror whose reconnect needs authentication.
    ///
    /// A reconnect runs on pipes with `BatchMode=yes` and no controlling tty, so a host
    /// that wants a password, MFA, or a security-key touch can never be satisfied by
    /// retrying. The connection stays parked in `.reconnecting`, which keeps the tmux
    /// session and every mirrored workspace intact, and this hands the user a real
    /// terminal to authenticate in.
    ///
    /// `sshArgv` is ``RemoteTmuxHost/interactiveAuthInvocation()``: under a tty it
    /// authenticates, opens the shared ControlMaster, runs a trivial remote `true`, and
    /// exits. Once the master is live the parked reconnect multiplexes over it with no
    /// further prompt. This is the same invocation the `cmux ssh-tmux` CLI runs when the
    /// initial attach reports ``RemoteTmuxAttachOutcome/authRequired(sshArgv:)``; a
    /// reconnect has no CLI in the loop, so cmux runs it in a workspace instead.
    ///
    /// Idempotent per host: a host with several mirrored sessions loses one control
    /// stream per session, and each would otherwise open its own login terminal racing
    /// for the same master. The first caller wins and later ones fold into it.
    /// - Returns: whether a login was actually put in front of the user. `false` means the
    ///   caller must fall back to retrying; treating "an observer exists" as handled is what
    ///   left a dismissed host parked with no retry and no waiter.
    @discardableResult
    func presentReconnectAuthentication(host: RemoteTmuxHost, sshArgv: [String]) -> Bool {
        guard !sshArgv.isEmpty else {
            Self.logger.error("reconnect-auth: empty sshArgv for \(host.connectionHash, privacy: .public)")
            return false
        }
        let key = host.connectionHash
        // A live connection to this host proves authentication is not the blocker, so asking
        // again is wrong. This is the straggler case: several sessions park, the user signs
        // in, the first to reconnect releases the offer, and a sibling still finishing its
        // pre-login attempt then reports auth-required into an empty slot — producing a
        // second login moments after a successful sign-in. Checked synchronously, before the
        // claim, so the reserve-before-create ordering is untouched.
        if Self.hasLiveConnection(
            states: sessionMirrors.values
                .filter { $0.host.connectionHash == key }
                .map(\.connection.connectionState)
        ) {
            Self.logger.info(
                "reconnect-auth: \(host.connectionHash, privacy: .public) already has a live connection; not offering")
            return false
        }
        // Reserve the slot BEFORE creating anything. Several sessions on one host report
        // auth-required in the same turn, and creating a workspace is not instantaneous;
        // recording afterwards let all of them through and opened a tab each.
        guard case .present(let generation) = loginOffers.claim(
            host: key, isOpen: { Self.workspaceExists($0) }
        ) else {
            if loginOffers.isDeclined(host: key) {
                // Report NOT presented, so the caller keeps retrying quietly. Claiming
                // otherwise is what stranded the host after a dismissal.
                Self.logger.info(
                    "reconnect-auth: login dismissed for \(host.connectionHash, privacy: .public); not re-offering")
                return false
            }
            Self.logger.info("reconnect-auth: login already offered for \(host.connectionHash, privacy: .public)")
            ensureAuthenticationWait(host: host)
            return true
        }
        let params = Self.reconnectAuthWorkspaceParams(host: host, sshArgv: sshArgv)
        // Go through `v2WorkspaceCreate`, the entry point the `workspace.create` socket
        // command uses, so the login workspace is created the same way as any other:
        // tab-manager resolution, window placement, and metadata refresh all included.
        // `addWorkspace` alone registers the workspace without surfacing it in a window.
        //
        // The policy wrapper is required, not decorative. `focus` is honored only while a
        // `workspace.create` allowance is on the calling thread's stack, which the socket
        // dispatcher pushes for real socket commands. Calling straight through from here
        // would create the login workspace unfocused and unselected — visible nowhere
        // until the user goes looking for it.
        let controller = TerminalController.shared
        let result = controller.withSocketCommandPolicy(
            commandKey: "workspace.create", isV2: true, params: params
        ) {
            controller.v2WorkspaceCreate(params: params)
        }
        Self.logger.info(
            "reconnect-auth: login workspace for \(host.connectionHash, privacy: .public): \(Self.loginWorkspaceOutcomeLabel(result), privacy: .public)")
        guard case .ok(let payload) = result,
              let workspaceId = (payload as? [String: Any])?["workspace_id"] as? String,
              let loginWorkspace = UUID(uuidString: workspaceId) else {
            // No login terminal exists, so nothing will ever arrive to unblock the mirror.
            // The connection is parked with its retry cancelled and the observer already
            // reported the event as handled, so leaving now would freeze the mirror for
            // good — the exact failure this feature removes. Hand it back to the retry
            // loop instead: it is rate-limited by backoff, and a later attempt can offer
            // the login again.
            Self.logger.error(
                "reconnect-auth: no login workspace for \(host.connectionHash, privacy: .public); resuming retries")
            loginOffers.abandon(host: key, generation: generation)
            resumeReconnectAfterAuthentication(host: host)
            return false
        }
        // Mark it so a relaunch does not restore a dead copy: a restored terminal is a fresh
        // shell that cannot authenticate, and it would be invisible to the per-host rule.
        if let manager = AppDelegate.shared?.tabManagerFor(tabId: loginWorkspace),
           let tab = manager.tabs.first(where: { $0.id == loginWorkspace }) {
            tab.isRemoteTmuxAuthLogin = true
        }
        loginOffers.recordOpened(host: key, workspace: loginWorkspace, generation: generation)
        awaitAuthenticationThenResume(host: host)
        return true
    }

    /// Releases a host's login offer because a mirror is connected again, and closes the
    /// login workspace cmux opened for it.
    ///
    /// Closing is what keeps a flapping host from collecting tabs. The alternative —
    /// releasing the slot but leaving the pane — means the next drop cannot see the pane
    /// that is already on screen and opens another, once per flap. cmux opened this
    /// workspace by itself for one purpose, and the reconnect proves that purpose is
    /// served, so cmux is the right owner to close it. A login the *user* dismissed is a
    /// different case and is already handled by the wait loop.
    func noteMirrorConnected(host: RemoteTmuxHost) {
        let key = host.connectionHash
        if loginOffers.hasOffer(host: key) {
            Self.logger.info("reconnect-auth: \(host.connectionHash, privacy: .public) reconnected; offer released")
            // Clear the offer BEFORE closing the workspace. `TabManager.closeWorkspace` reports
            // every login workspace to `noteLoginWorkspaceClosed`, which cannot tell cmux's own
            // close from the user's: with the offer still present it takes the decline path on a
            // successful reconnect and logs a dismissal that never happened. Clearing first makes
            // that re-entry inert instead of relying on the call below to undo it.
            let offer = loginOffers.openedWorkspace(host: key)
            loginOffers.noteConnected(host: key)
            if let offer { closeLoginWorkspace(offer.workspace) }
        }
        // The host is authenticated, so any waiter for it has nothing left to wait on. Its
        // guards would end it on the next tick anyway; cancelling means it stops now rather
        // than running one more `ssh -O check` for a question already answered.
        cancelAuthWait(host: key)
        // One mirror connecting proves the master is authenticated, and the host's other
        // parked connections are waiting on exactly that. Releasing the offer without
        // resuming them leaves those mirrors frozen with their waiter already gone, since
        // the waiter exits once the offer disappears.
        resumeReconnectAfterAuthentication(host: host)
    }

    /// Releases a host's login offer once nothing is left for it to unblock.
    ///
    /// A login exists to unfreeze mirrors. When the last mirror for the host goes away — closed,
    /// detached, or taken with its window — the offer, its waiter and the sign-in pane are all
    /// orphaned: the waiter would keep watching a socket nobody is waiting on, and the pane would
    /// sit there with nothing to resume. Called from every path that removes a mirror, because
    /// which path ran is not something the offer should have to know.
    func releaseLoginOfferIfHostHasNoMirrors(host: RemoteTmuxHost) {
        let key = host.connectionHash
        guard loginOffers.hasOffer(host: key) else { return }
        guard !sessionMirrors.values.contains(where: { $0.host.connectionHash == key }) else { return }
        // Release before closing, for the same reason as `noteMirrorConnected`: the close path
        // re-enters `noteLoginWorkspaceClosed`, and an offer still present sends it down the
        // decline path for a workspace cmux is retiring itself.
        if let offer = loginOffers.openedWorkspace(host: key) {
            loginOffers.abandon(host: key, generation: offer.generation)
            closeLoginWorkspace(offer.workspace)
        } else {
            loginOffers.noteConnected(host: key)
        }
        cancelAuthWait(host: key)
    }

    /// Stops a host's login waiter.
    ///
    /// Held so it can be stopped: the waiter probes the shared master on a timer, and one that
    /// outlives its offer would keep probing with nothing able to stop it.
    func cancelAuthWait(host key: String) {
        authWaitTasks[key]?.cancel()
        authWaitTasks[key] = nil
        hostsWaitingForAuth.remove(key)
    }

    /// Closes a login workspace wherever it lives, if it still exists.
    private func closeLoginWorkspace(_ workspace: UUID) {
        guard let appDelegate = AppDelegate.shared,
              let manager = appDelegate.tabManagerFor(tabId: workspace),
              let tab = manager.tabs.first(where: { $0.id == workspace }) else { return }
        // `closeWorkspace` refuses to close the last tab in a window, so a login that ended up
        // alone in its own window could not be closed at all: the offer cleared while the obsolete
        // sign-in shell stayed on screen, and cmux opened it, so cmux has to be able to remove it.
        // Discarding the window is the equivalent action when the login *is* the window.
        if manager.tabs.count <= 1, let windowId = appDelegate.windowId(for: manager) {
            appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId)
            return
        }
        manager.closeWorkspace(tab, recordHistory: false)
    }

    /// Whether any of a host's connections is live, meaning authentication is not the
    /// blocker and a login must not be offered.
    ///
    /// Only `.connected` counts. `.reconnecting` is precisely the parked state a login exists
    /// for, and `.connecting` has not proven anything yet — treating either as live would
    /// suppress the offer the user needs.
    nonisolated static func hasLiveConnection(states: [RemoteTmuxConnectionState]) -> Bool {
        states.contains(.connected)
    }

    /// Whether a workspace still exists in any window.
    static func workspaceExists(_ workspace: UUID) -> Bool {
        AppDelegate.shared?.tabManagerFor(tabId: workspace) != nil
    }

    /// Starts the wait for authentication unless one is already running for this host, so
    /// a repeat auth-required that folds into an existing offer still gets resumed.
    private func ensureAuthenticationWait(host: RemoteTmuxHost) {
        guard !hostsWaitingForAuth.contains(host.connectionHash) else { return }
        awaitAuthenticationThenResume(host: host)
    }

    /// The `workspace.create` parameters for a host's login workspace.
    ///
    /// Separate and `nonisolated` so a test can assert these params actually earn a focus
    /// allowance: `focus` is only honored for methods in
    /// ``TerminalController/explicitFocusParamV2Methods``, so dropping or renaming the key
    /// would silently produce an unfocused login workspace.
    nonisolated static func reconnectAuthWorkspaceParams(
        host: RemoteTmuxHost, sshArgv: [String]
    ) -> [String: Any] {
        [
            "title": String.localizedStringWithFormat(
                String(
                    localized: "remoteTmux.reconnectAuth.workspaceTitle",
                    defaultValue: "Sign in to %@"
                ),
                host.destination
            ),
            "initial_command": interactiveAuthShellCommand(sshArgv: sshArgv),
            "focus": true,
            "eager_load_terminal": true,
        ]
    }

    /// Waits for the login terminal to open the shared master, then resumes.
    ///
    /// Waiting on a *person* rules out a deadline — an MFA push or a hardware-key touch can take
    /// seconds or many minutes, and a wait that expired while the login terminal was still open
    /// would strand the mirror, parked with retrying stopped and nothing left to resume it. It
    /// does not rule out an event, which is the mistake an earlier version of this made: opening
    /// the master creates the socket at ``RemoteTmuxHost/controlSocketPath``, so the filesystem
    /// reports the moment being waited for and ``FileWatcher`` delivers it.
    ///
    /// `ssh -O check` (``RemoteTmuxSSHTransport/isMasterLive()``) is still how the socket is
    /// confirmed usable rather than stale — local, instant, and unable to prompt, so it can never
    /// consume an authentication attempt mid-login — but it runs once per event instead of on a
    /// clock. A timer's interval is dead time a frozen mirror spends *after* the user has already
    /// finished, and no interval is short enough to make that right.
    ///
    /// So the wait ends on state rather than on a clock, and every ending is derived by
    /// looking at what exists rather than by trusting some teardown path to signal:
    ///
    /// - the master comes up, so the mirror resumes;
    /// - the host has no mirror left (workspace closed, host detached, app quitting), so
    ///   there is nothing to authenticate for;
    /// - the user closed the login without finishing it, so nothing will arrive — the
    ///   connection goes back to retrying, and a later failure offers a fresh login. Left
    ///   parked instead, that host would have no route back short of restarting cmux.
    ///
    /// The wait ends on an event, so there is no interval to tune and no dead time behind one.
    private func awaitAuthenticationThenResume(host: RemoteTmuxHost) {
        let key = host.connectionHash
        let transport = transport(for: host)
        hostsWaitingForAuth.insert(key)
        authWaitTasks[key]?.cancel()
        // A waiter must only retract its own registration. Cancelling W1 and storing W2 runs W1's
        // `defer` afterwards, and an unconditional clear there would delete W2's entry — leaving a
        // live waiter invisible to both dismissal and teardown, which is worse than the stale
        // waiter this replacement was meant to fix.
        authWaitGeneration &+= 1
        let waiterId = authWaitGeneration
        authWaitIds[key] = waiterId
        authWaitTasks[key] = Task { @MainActor [weak self] in
            defer {
                if self?.authWaitIds[key] == waiterId {
                    self?.hostsWaitingForAuth.remove(key)
                    self?.authWaitTasks[key] = nil
                    self?.authWaitIds[key] = nil
                }
            }
            // Edge-driven, not polled. Completing the login is the user opening the shared ssh
            // master, and opening it creates the socket at cmux's own ControlPath — so the
            // filesystem already reports the exact moment being waited for. `FileWatcher` watches
            // the path's parent directory too, which is what makes creation (not just change)
            // visible, and this socket does not exist yet when the wait starts.
            //
            // A timer here would be strictly worse: the interval is dead time a frozen mirror
            // spends after the user has finished, and no interval is short enough to be right —
            // this is a person typing a password, not a bounded computation.
            //
            // `isMasterLive()` still runs, but once per event rather than on a clock: the socket
            // appearing is the edge, and `ssh -O check` is how we confirm it is usable rather
            // than a stale file. The loop continues on a negative answer because the directory
            // reports unrelated churn too (other hosts' masters live in the same directory).
            let watcher = FileWatcher(path: host.controlSocketPath)
            defer { Task { await watcher.stop() } }
            // The edge has to actually exist. `FileWatcher` returns nil from a failed
            // `open(O_EVTONLY)` and carries on, so under permission loss or fd exhaustion (EMFILE)
            // the stream exists with no source behind it and can never yield — the login would
            // complete and this wait would never hear about it. Ask the watcher instead of putting
            // a timer behind it: on a failed watch, hand the host back to the connection's own
            // bounded backoff, which already owns retrying, and a later failure offers the login
            // again with a fresh watch attempt. The login pane stays up either way, so the user can
            // still finish signing in.
            guard await watcher.isWatchingAncestorDirectory else {
                Self.logger.error(
                    "reconnect-auth: could not watch the control socket path; falling back to reconnect retries")
                self?.resumeReconnectAfterAuthentication(host: host)
                return
            }
            // The master may already be live: the user can finish signing in between the failure
            // that parked this connection and this waiter starting, and an edge that already
            // happened is never delivered. Checking once up front is what stops an event-driven
            // wait from hanging on a condition that was true before anyone was listening.
            if await transport.isMasterLive() {
                self?.resumeReconnectAfterAuthentication(host: host)
                return
            }
            for await _ in watcher.events {
                guard let self else { return }
                if Task.isCancelled { return }
                // Another path already gave up on this host, or replaced this offer with a
                // newer one that its own waiter owns.
                guard let offer = loginOffers.openedWorkspace(host: key) else { return }
                guard sessionMirrors.values.contains(where: { $0.host.connectionHash == key })
                else {
                    // The mirror this login existed for is gone; leaving the pane behind
                    // would strand a tab nothing can ever close.
                    closeLoginWorkspace(offer.workspace)
                    loginOffers.abandon(host: key, generation: offer.generation)
                    return
                }
                if await transport.isMasterLive() {
                    self.resumeReconnectAfterAuthentication(host: host)
                    return
                }
            }
        }
    }

    /// The user closed a login cmux opened, which is a decline.
    ///
    /// Called from the close path rather than noticed by the waiter: a closed tab produces no
    /// filesystem or protocol event, so this is the only edge for it. Retrying resumes quietly so
    /// a host that starts accepting authentication recovers on its own, while the offer is marked
    /// declined for this outage — otherwise the retry fails the same way, a new login opens, and
    /// closing the tab looks like it did nothing.
    func noteLoginWorkspaceClosed(workspaceId: UUID) {
        guard let key = loginOffers.host(forOpenedWorkspace: workspaceId) else { return }
        guard let offer = loginOffers.openedWorkspace(host: key) else { return }
        // No mirror left for this host means there is nothing to resume, so recording the decline
        // is the whole job: it stops this outage from offering another login the user would have
        // to dismiss again.
        guard let host = sessionMirrors.values.first(where: { $0.host.connectionHash == key })?.host
        else {
            loginOffers.noteDeclined(host: key, generation: offer.generation)
            cancelAuthWait(host: key)
            return
        }
        Self.logger.info(
            "reconnect-auth: login dismissed for \(host.connectionHash, privacy: .public); retrying quietly")
        loginOffers.noteDeclined(host: key, generation: offer.generation)
        cancelAuthWait(host: key)
        resumeReconnectAfterAuthentication(host: host)
    }

    /// Resumes every parked control connection for `host` after authentication.
    ///
    /// Per host, not per session: one authenticated ControlMaster unblocks every session
    /// mirrored from that host. Each connection's `resumeAfterInteractiveAuth()` is a
    /// no-op unless it is actually parked, so this cannot disturb a healthy stream.
    func resumeReconnectAfterAuthentication(host: RemoteTmuxHost) {
        let key = host.connectionHash
        // Deliberately no release here. A resume is an *attempt*; it can fail
        // authentication again, and releasing on the attempt opened a new login tab per
        // failure. ``noteMirrorConnected(host:)`` releases it once the host is actually back.
        for mirror in sessionMirrors.values where mirror.host.connectionHash == key {
            mirror.connection.resumeAfterInteractiveAuth()
        }
    }

    /// The command the login terminal runs.
    ///
    /// Every argv element is single-quoted, so a destination carrying shell
    /// metacharacters cannot inject anything.
    ///
    /// The whole payload is handed to an explicit `/bin/sh -c`, which is load-bearing
    /// rather than stylistic. A terminal command runs as
    /// `bash --noprofile --norc -c "exec -l <command>"`, and that `exec -l` replaces the
    /// shell with the command's *first* program — so with the ssh invocation written at
    /// the top level, everything after it (the result message, and the interactive shell
    /// that keeps the pane alive) is unreachable. The pane would then die the instant ssh
    /// exits, on success and on failure alike, and cmux closes a workspace whose child
    /// exited: the login tab appears and vanishes in well under a second, taking the
    /// reason with it. Wrapping means `exec -l` replaces bash with `sh`, which then runs
    /// the payload to completion.
    ///
    /// Falling into an interactive shell at the end also leaves the user somewhere to
    /// read the message and retry from.
    nonisolated static func interactiveAuthShellCommand(sshArgv: [String]) -> String {
        let quoted = sshArgv.map { RemoteTmuxHost.shellSingleQuoted($0) }.joined(separator: " ")
        let ok = RemoteTmuxHost.shellSingleQuoted(String(
            localized: "remoteTmux.reconnectAuth.success",
            defaultValue: "Signed in. Reconnecting the mirror…"
        ))
        let failed = RemoteTmuxHost.shellSingleQuoted(String(
            localized: "remoteTmux.reconnectAuth.failure",
            defaultValue: "Sign-in failed. Run the command above again to retry."
        ))
        // Empty counts as unset: `exec '' -i` would kill the pane the moment ssh returns.
        let configuredShell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let shell = RemoteTmuxHost.shellSingleQuoted(
            configuredShell.isEmpty ? "/bin/zsh" : configuredShell)
        // Echo the invocation first. The failure message says to run the command again, which
        // is unfollowable if the command was never shown: `ssh` prints its own prompts, not
        // its argv. One printf with the whole line as a single operand — `printf 'x %s\\n' a b`
        // would repeat the format per element.
        let banner = RemoteTmuxHost.shellSingleQuoted("+ \(quoted)")
        let payload =
            "printf '%s\\n' \(banner); "
            + "\(quoted) && printf '%s\\n' \(ok) || printf '%s\\n' \(failed); exec \(shell) -i"
        return "/bin/sh -c \(RemoteTmuxHost.shellSingleQuoted(payload))"
    }

    /// Names a `V2CallResult` for a public log line without publishing what it carries.
    /// `.ok` wraps the created workspace's fields and `.err` carries an arbitrary `data`
    /// value, so interpolating the whole result would put both in the system log. The
    /// error code is a fixed identifier rather than caller data, so it stays public and
    /// keeps the line useful for diagnosing a failed login-workspace create.
    private static func loginWorkspaceOutcomeLabel(
        _ result: TerminalController.V2CallResult
    ) -> String {
        switch result {
        case .ok:
            return "ok"
        case .err(let code, _, _):
            return "err(\(code))"
        }
    }

}
