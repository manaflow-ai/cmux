import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
// Re-exported: every App file and `@testable import CmuxNextApp` test reads Cloud's start-session strings (CloudStartSessionStrings).
@_exported import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextRemote
import CmuxNextSettings
import CmuxNextTabs
import Foundation

/// A new chat's first send with Cloud picked as where it runs (`cloud.startChat`, ``AgentPaneCloudStart``; leo-workspace design/cloud-work-mode.md):
/// the chat goes to Cloud with no machine, size or environment prompt. It takes a free Cloud machine of this person's, else a new one for chats sized
/// for the chat by ``CloudChatPick`` (``machine(for:account:workspace:cli:invocation:pick:)``), copies the chat's folder to a folder of the send's
/// own there, and opens a new chat on that machine in the copied folder whose first prompt is the person's (a seeded prompt, sent once with the
/// Send's gesture, as onboarding's first task). This Mac's tab, which never started a chat, then closes.
///
/// The page's card shows progress and failures; nothing moves, so no Move to Cloud toast (Leo, 2026-11-04: "why is this showing up when i create a
/// new chat"). Not behind Labs: it needs Cloud allowed and a signed-in account (``refusal(_:)``). A chat with no project
/// (``AgentPaneCloudStart/home``) copies nothing and opens in the machine's own folder.
@MainActor
struct CloudStartChat {
    let services: AppServices
    /// Where the start's questions show: the sending pane's card for a composer start; nil asks in a
    /// dialog on the active window.
    var asker: AgentPaneCloudAsker?
    var timeline: CloudSendTimeline? // to the chat's first token (cmux#45953); its tab marks the rest (CloudSendTimelines)

    /// The page's runner for every pane (``AgentPageChats/seed(_:)``): `view` is the pane that sent.
    static func runner(_ tabs: AgentTabStore, services: AppServices) -> @MainActor (AgentPaneView?, AgentPaneCloudStart) async -> [String: Any] {
        { [weak tabs, weak services] view, start in
            guard let services else { return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled") }
            // Only a tab of this Mac's daemon: the folder it names is copied from this Mac.
            guard let view, let scoped = tabs?.views.entries.first(where: { $0.value === view })?.key,
                  let (tab, _) = services.locateTab(scoped.key, onMachine: scoped.machine),
                  services.machines.daemon(forTab: tab).isLocal else {
                return AgentPaneReply.failure(code: "unavailable", message: CloudMoveStrings.notAChat)
            }
            let timeline = CloudSendTimeline() // from the Send's arrival here (cmux#45953)
            let titles = services.cloudStartTitles, workspace = services.workspaceID(ofTab: tab.id); titles.begin(tab, task: start.task, untitled: AgentPaneModel.tabTitle); defer { titles.end(tab); titles.endWorkspace(workspace) } // the page reads as its chat from the Send
            return await CloudStartChat(services: services, asker: .card(view, start: start.key), timeline: timeline).reply(start, tab: tab) { [weak view] step in
                if let view { start.progress(step, to: view) }
            }
        }
    }

    /// The page's reply: the machine's name, or a refusal the card says (no toast), with Retry when another try can help.
    /// `report` tells the page's card each step as it begins (``AgentPaneCloudStart/progress(_:folder:machine:size:to:)``).
    func reply(_ start: AgentPaneCloudStart, tab: TabModel, report: @MainActor (AgentPaneCloudStart.Step) -> Void = { _ in }) async -> [String: Any] {
        if let refusal = Self.refusal(services) {
            return AgentPaneReply.failure(code: refusal, message: CloudStrings.startRefusal(refusal))
        }
        do {
            if let team = start.team { try await services.cloud.auth.activeTeam.select(team) } // the plan card's Switch to <team>, then only in it:
            if let refused = CloudStartCore().refusal(cloudDisabled: false, signedIn: true, requestedTeam: start.team, activeTeam: services.cloud.auth.teamID) { return AgentPaneReply.failure(code: refused, message: refused, details: nil, retryable: true, origin: "native") }
            // The copy's preflight (a read of the folder, no machine) runs beside Cloud first use's read below, not after it (cmux#45953).
            let folder = start.home || start.repository != nil ? nil : (start.cwd ?? tab.cwd).flatMap(CloudMoveFolder.init(chat:)).flatMap { $0.isTooBroad ? nil : $0 }
            let preflight = folder.flatMap { folder in services.cloud.move.cli.map { CloudStartPreflight(root: folder.root, cli: CloudMoveCLI(binary: $0, timeout: services.cloud.move.timeout)) } }
            defer { preflight?.cancel() } // unused when the start ends before it, or takes another folder
            // Cloud first use, read in the team the start runs in: the connection the chat runs on (its credential goes
            // with the agent launch, ``open``); nothing serving the picker's model shows Set up Cloud and starts nothing.
            let choice = await services.cloud.setup.choose(harness: start.harness, model: start.model, account: start.account)
            if case .setup(let family, let model) = choice {
                return AgentPaneReply.failure(code: "cloud_setup_required", message: "cloud_setup_required", details: ["family": family, "model": model ?? ""], retryable: false, origin: "native")
            }
            let account = services.cloud.account
            var origin = Origin(tab: tab, chat: start.repository == nil ? start.cwd ?? tab.cwd : nil, workspace: services.workspaceID(ofTab: tab.id), account: account, connection: choice.connectionID) { [services] in
                // This Mac's tab, which never started a chat: the chat is the machine's now.
                do {
                    try await services.daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
                } catch {
                    services.cloud.logger.error("cloud start chat: closing this Mac's tab failed: \(String(describing: error), privacy: .public)")
                }
            }
            origin.preflight = preflight
            let machine = try await run(start, from: origin, report: report)
            return AgentPaneReply.success(["machine": machine])
        } catch is CloudMoveFolder.Gone { // the card's own words, with no Retry: picking another folder is the way on
            return AgentPaneCloudFolderRefusal.missing.reply
        } catch let needs as CloudMachineRoute.NeedsConnection { return await start.needsConnectionReply(needs.message, setup: services.cloud.setup) // its agent reaches no model there (cmux#45773)
        } catch is CloudMachineCap.RunHere { // the cap card's Run on This Mac: the page sends it here (cloudRun.ts)
            return AgentPaneReply.failure(code: CloudMachineCap.runHereCode, message: CloudMachineCap.runHereCode)
        } catch let refusal as CloudMoveCLI.StartChatPreflightRefusal { return refusal.reply // the repos inside it, another folder or none; no Retry
        } catch let refusal as AgentPaneCloudRepositoryRefusal { return refusal.reply } catch let locked as CloudSizeLocked { return locked.reply(planMax: nil) // a repository's clone: Connect GitHub, then Retry; a size the plan lacks: its upgrade
        } catch {
            let message = (error as? CloudMove.Failure)?.message ?? (error as? ActionFailure)?.message
                ?? CloudMoveStrings.moveFailed(CloudStrings.errorText(error))
            services.cloud.logger.error("cloud start chat failed: \(message, privacy: .public)")
            // A failure a retry can help gets the card's Retry; a plan refusal keeps its code and the teams (CloudStartView).
            let plan = CloudMachineCreation.proRefusal(error) != nil
            return AgentPaneReply.failure(code: plan ? "cloud_plan_required" : (error as? CloudMove.Failure)?.code ?? "cloud_start_failed", message: message, details: plan ? AgentPaneCloudMachines.Plan.requiredDetails(services.cloud.auth.planRefusalTeams) : nil, retryable: (error as? CloudMove.Failure).map { $0.retry != nil || $0.sendAgain } ?? false, origin: "native")
        }
    }

    /// Why no Cloud chat can start at all now, the sandbox's codes (`AgentPageChats.wireSandbox`):
    /// Cloud off by policy, or not signed in. Either link takes the start: the Cloud app server's
    /// carrier socket serves each connection as its own dial of the machine's daemon, so the copy's
    /// CLI gets a connection beside the app's (``CloudMove/connected(_:_:)``). Not behind Labs (Leo,
    /// 2026-10-30: "that seems dumb. i dont like putting so much stuff in labs"): the person picked
    /// Cloud for this send.
    static func refusal(_ services: AppServices) -> String? { CloudStartCore().refusal(cloudDisabled: services.registry.disabledFeatures.contains(.cloud) || !services.cloud.mayCallCloud, signedIn: services.cloud.isSignedIn) } // the rule: cmux-cloud-start-core `start`

    /// Where a start comes from: the tab that sent (this Mac's new tab, or for a repick the chat's tab on the machine it was on), the chat's folder
    /// on this Mac, the Mac workspace and account the send began in, and what closes the tab once the chat opened on its machine.
    struct Origin {
        let tab: TabModel
        let chat: String?
        let workspace: String?
        let account: [String?]
        /// This Mac's connection the chat's agent launches on (``CloudSetup/Choice/connectionID``); nil: the machine's own route.
        var connection: String?
        var preflight: CloudStartPreflight? // begun before Cloud first use's read; nil: the start runs its own
        let close: @MainActor () async -> Void
    }

    /// The start; returns the machine's name.
    func run(_ start: AgentPaneCloudStart, from origin: Origin, report: @MainActor (AgentPaneCloudStart.Step) -> Void) async throws -> String {
        let tab = origin.tab
        guard !start.home, start.repository == nil else { return try await runHome(start, from: origin, report: report) } // a repository is cloned there: nothing is copied
        // The folder the page named, as Move to Cloud's `path` takes one: an existing folder, never
        // the home folder or the disk's root. A page could already start a chat on this Mac in it.
        guard let chat = origin.chat, await CloudMoveFolder.isFolder(chat),
              let folder = CloudMoveFolder(chat: chat) else { throw CloudMove.Failure(message: CloudMoveStrings.noFolder) }
        guard !folder.isTooBroad else { throw CloudMove.Failure(message: CloudMoveStrings.homeFolder) }
        // A folder the page named is copied only as the pane checked it: its upload root, never home
        // or a credential folder (``AgentPaneHandOff``). A `.git` found above it since then is refused.
        guard start.uploads(folder) else { throw CloudMove.Failure(message: CloudMoveStrings.noFolder) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .user)
        let folderName = (chat as NSString).lastPathComponent
        let start = try await start.sized(CloudStartPreflight.answer(origin.preflight, root: folder.root, cli: cli), local: folder.root) // before any machine or lease: the size its copy needs, or its refusal
        timeline?.mark("preflight")
        report(.init(name: "machine", folder: folderName))
        let gateway = services.cloud.gateway.onlineBeside(within: .seconds(10)) // No login step (PersonalGateway): only the first prompt needs it, so it comes up beside the start
        // The machine, the pin and the keys are cmux-tui's (`cmux link start-chat`, +Machine).
        let account = origin.account, holding = CloudStartGate.Holding(); do {
        let (machine, plan) = try await CloudSizeLocked.naming(start.size, bytes: start.folderBytes) { try await self.machine(for: start, account: account, workspace: origin.workspace, connection: origin.connection, cli: cli, invocation: invocation, holding: holding) {
            await CloudChatPick(services: services).read(folder: chat, tab: tab)
        } } // a refusal of its size names the size and the folder
        timeline?.mark("machine") // the pick or create, and its link
        _ = holding.keep(machine.machineID, in: services.cloud.startGate, until: timeline); return try await plan.releasing(sameAccount: { account == services.cloud.account }, delete: { try await cli.strandThenDelete(key: start.key, account: CloudStartCore().accountText(account), machine: machine.machineID) { try await services.cloud.deleteMachine($0) } }) { // a start that can't go on deletes its machine
            let name = machine.machine.title, again = CloudMoveRetries.Retry.move(machineID: machine.machineID)
            // The account may have changed while the machine connected: copy nothing then.
            try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
            let size = AgentPaneCloudStart.sizeText(machine.machine.size) // Remote approvals run beside the copy, awaited before the chat opens.
            let copy: Copied = try await RemoteApprovalPreparations.owned({ [services] in await services.cloud.restartWithApprovalsIfIdle(machine, .checkStatus) { account == services.cloud.account } }) {
                report(.init(name: "folder", folder: folderName, machine: name, size: size))
                guard await CloudMoveFolder.isFolder(folder.root) else { throw CloudMoveFolder.Gone() } // removed while the machine came up
                // Each copy goes to a new folder of the send's own, under its account as its pin; a retry whose
                // copy finished opens its chat without copying again, which would overwrite what it changed.
                // A refused git seed copies the folder with no question; a copy the machine's disk cannot hold ends the start with its reason (CloudSeedRefusal), Retry kept on this machine.
                let copy: Copied
                do {
                    copy = try await copyFolder(folder, key: start.key, account: account, to: machine, cli: cli,
                                                declined: { CloudMove.Failure(message: $0.tooLarge, code: $0.pageCode, retry: again) },
                                                // Timed out or didn't launch: Retry copies again on this machine, into a new folder.
                                                failed: { CloudMove.Failure(message: CloudMoveStrings.syncFailed(name, CloudStrings.errorText($0)), retry: again) }) {
                        report(AgentPaneCloudStart.copying($0, folder: folderName, machine: name, size: size))
                    }
                } catch {
                    throw await CloudMoveFolder.orGone(error, root: folder.root)
                }
                report(.init(name: "folder", folder: folderName, machine: name, size: size,
                             cloneState: copy.0.seedState, clonePhase: copy.0.seedPhase,
                             cloneStartedAt: copy.0.seedStartedAt, cloneFinishedAt: copy.0.seedFinishedAt,
                             start: .init(environmentId: plan.environmentId, setup: plan.setup), leftOnMac: copy.0.leftOnMac))
                guard copy.0.ok else { throw await CloudMoveFolder.orGone(CloudMoveFailure.syncing(copy.0, machine: name, retry: again), root: folder.root) }
                timeline?.mark("copy")
                return copy
            }
            timeline?.mark("approvals") // 0 ms when they finished beside the copy
            // The copy may take long: a chat whose account changed meanwhile opens nowhere, and this Mac's tab stays.
            try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
            report(.init(name: "opening", folder: folderName, machine: name, size: size,
                         start: .init(environmentId: plan.environmentId, setup: plan.setup)))
            _ = await gateway.value
            timeline?.mark("gateway") // 0 ms when it came up beside the steps
            let entry = AgentTabStore.registryHost(of: machine.daemon).map {
                CloudMovedChats.Entry(machineID: machine.machineID, host: $0, session: "", harness: start.harness,
                                      localRoot: folder.root, localChat: chat, remoteFolder: copy.1.folder, remoteChat: copy.1.chat)
            }
            return try await open(start, from: origin, on: machine, cwd: copy.1.chat, trusted: copy.1.sourceTrusted, tabKey: plan.tabKey, copy: entry)
        } } catch { holding.end(); throw error }
    }

    /// What a copy answers: the CLI's answer, the chat's folder and the copied folder on the machine, whether it copied now (false: an earlier copy under the key finished) and whether this Mac trusts the source.
    typealias Copied = (CloudMoveCLI.Answer, (chat: String, folder: String, copied: Bool, sourceTrusted: Bool))

    /// Copies `folder` to a new folder of the start's own on `machine` (`cmux link start-chat copy`), under `key` and
    /// `account` as its pin: the composer's Cloud start and `cmux cloud start-session --from-folder` alike
    /// (``CloudStartSession``). A start whose copy under `key` already finished on `machine` gets that copy's folder,
    /// never copied again: that would overwrite what its chat changed. `progress` gets the copy's progress lines.
    /// A machine that can't clone the folder from its git remote gets the whole folder copied, never asked; a copy its
    /// disk cannot hold (``CloudSeedRefusal``) throws `declined(refusal)`. A copy that times out or doesn't launch throws `failed(error)`.
    func copyFolder(_ folder: CloudMoveFolder, key: String, account: [String?], to machine: CloudMachineSession, cli: CloudMoveCLI,
                    declined: (CloudSeedRefusal) -> any Error, failed: (any Error) -> any Error,
                    progress: (SeedProgress) -> Void) async throws -> Copied {
        let name = machine.machine.title, storeAccess = await services.cloud.auth.startChatStoreAccess(account: account)
        // A machine whose older cmux-tui refuses the copy is updated to this app's build, then copied again on its new link (CloudOutdatedMachine);
        // the copy's progress lines go to the clone row as they come, about 4 a second (SeedProgress.feed).
        return try await CloudSeedRefusal.copying(machine: name, diskMb: machine.machine.size?.storageMb, grow: { await self.growDisk(machine, for: $0) }, declined: declined) { refusal in do {
                return try await CloudOutdatedMachine.copy(socket: { await machine.daemon.connection?.endpoint?.socketPath },
                                                           link: { CloudMachineUpdates.handshake(machine, machines: services.machines) },
                                                           notConnected: CloudMove.Failure(message: CloudMoveStrings.notConnected(name))) { socket in try await SeedProgress.feed({ [cli, refusal, key, owner = CloudStartCore().accountText(account), id = machine.machineID, root = folder.root, sub = folder.subpath, roots = services.cloud.move.workRoots, home = QuitAgents.environment(services)?.home.path, storeAccess] line in
                        try await cli.startChatCopy(key: key, account: owner, machine: id, socket: socket, local: root, subpath: sub, workRoots: roots, acpmuxHome: home, access: storeAccess, onSeedRefusal: refusal, stderrLine: line)
                    }, each: progress)
                } answer: { ($0.0.ok, $0.0.errorCode, $0.0.side) } update: { await CloudMachineUpdates.updateNow(machine.machineID, services: services) }
            } catch {
                throw failed(error)
        } }
    }

    /// Opens the chat on `machine` in `cwd` under the plan's `tabKey` (a retry gets the same tab) and closes the origin's tab: the chat is the
    /// machine's now. A copy of a folder this Mac trusts (`trusted`) is trusted there first. The opened tab is kept with its start, so another
    /// machine picked before its first send runs moves it there (+Repick).
    func open(_ start: AgentPaneCloudStart, from origin: Origin, on machine: CloudMachineSession, cwd: String?,
              trusted: Bool = false, tabKey: String, copy: CloudMovedChats.Entry? = nil) async throws -> String {
        guard !start.attachments.isEmpty else { return try await openUploaded(start, from: origin, on: machine, cwd: cwd, trusted: trusted, tabKey: tabKey, copy: copy) }
        await CloudOutdatedMachine.updateBeforeUsingCapability(holds: { machine.daemon.supports(DaemonCapability.agentSessionContent.rawValue) }, update: { await CloudMachineUpdates.updateNow(machine.machineID, services: services) })
        guard machine.daemon.supports(DaemonCapability.agentSessionContent.rawValue), let carry = AgentPaneCloudAttachments(start.attachments, files: start.carriedFiles, staged: start.stagedFiles), let pastes = CloudUploads.pastes,
              let binary = services.cloud.move.cli, let socket = await machine.daemon.connection?.endpoint?.socketPath,
              let root = cwd.flatMap(services.cloud.move.workRoot(of:)) ?? services.cloud.move.workRoots.first else { throw CloudMove.Failure(message: CloudUploadStrings.failed) }
        let access = CloudAccessCLI(binary: binary)
        return try await carry.withUploaded(in: pastes, upload: { paths in
            try Self.checkAccount(origin.account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
            let answer = try await access.upload(socket: socket, remoteRoot: root, files: paths)
            guard answer.ok else { try? await access.removeUploads(socket: socket, remoteRoot: root, ids: answer.uploadIDs); throw CloudMove.Failure(message: CloudUploadStrings.failed) }
            return .init(paths: answer.uploaded, undo: { try? await access.removeUploads(socket: socket, remoteRoot: root, ids: answer.uploadIDs) })
        }) { attachments in
            try Self.checkAccount(origin.account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
            var uploaded = start
            uploaded.attachments = attachments
            return try await openUploaded(uploaded, from: origin, on: machine, cwd: cwd, trusted: trusted, tabKey: tabKey, copy: copy, original: start)
        }
    }

    private func openUploaded(_ start: AgentPaneCloudStart, from origin: Origin, on machine: CloudMachineSession, cwd: String?,
                              trusted: Bool, tabKey: String, copy: CloudMovedChats.Entry? = nil,
                              original: AgentPaneCloudStart? = nil) async throws -> String {
        // A chosen model connection goes with the launch only to a daemon that takes one (an image's older daemon dropped it and the provider refused the agent): a connected one that lacks it after a refused or bounded update ends the start, saying so.
        try await CloudOutdatedMachine.requireCapability(
            holds: { services.agentTabs.holdsTabs(machine.daemon) && (origin.connection == nil || machine.daemon.supports(AgentSessionAttachClient.credentialsCapability(harness: start.harness))) }, lacks: { origin.connection != nil && machine.daemon.connection != nil && !machine.daemon.supports(AgentSessionAttachClient.credentialsCapability(harness: start.harness)) },
            update: { await CloudMachineUpdates.updateNow(machine.machineID, services: services) }, missing: CloudMove.Failure(message: CloudMachineRoute.tooOld, retry: .move(machineID: machine.machineID)))
        let context = AppActionContext(services: services), daemon = machine.daemon, failure = CloudMove.Failure(message: CloudMoveStrings.notConnected(machine.machine.title), retry: .move(machineID: machine.machineID))
        let (seed, handOff) = AgentPaneSeedSource.handingOffDraft(start.seed(cwd: cwd)) { [services] in services.agentTabs.unsentDrafts.draft(forTab: services.agentTabs.resolve(origin.tab.id), machine: services.agentTabs.daemonListing(origin.tab)?.machineID) }
        defer { handOff(false) }
        // The chat's agent launch reads this choice (AgentTabs+RemoteStart): set before the tab exists, under the tab's key.
        services.cloud.agentCredentials.use(connection: origin.connection, chat: tabKey, machine: machine.machineID)
        let inPlace = Self.frontsInPlace(origin.tab, workspace: CloudMachineWorkspace.chatKey(tabKey: tabKey).rawValue, services: services); let open = { (workspace: WorkspaceHandle) in try await services.agentTabs.openFirstPage(workspace: workspace, cwd: cwd, on: daemon, source: seed, mutationID: tabKey) }
        // The chat's own workspace, the chat its only tab: never the machine's first workspace and its starter terminal. The link can be down or drop under this (CloudMachineWorkspace.chatRelinked): it opens once more on the new link, under the same key.
        let (anchor, tab, opened) = try await CloudMachineWorkspace.chatRelinked(in: daemon.store, held: machine.linkHeld) {
            guard let connection = daemon.connection else { throw failure }
            let made = try await CloudMachineWorkspace.chat(tabKey: tabKey, in: daemon.store, notConnected: failure, open: open) { key in
                _ = try await services.machines.local.connection?.pinWorkspaceBeforeCreate(session: daemon.store.registryID, key: key, to: services.machines.local.store.profile(services.windows.active?.state.profileID ?? .defaultProfile)?.id)
                return try await WorkspaceCreation.createWithFirstTab(key, name: nil, on: connection, repair: services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)) { try await open($0.workspace) }
            }
            guard let surface = made.tab, let anchor = await CloudHandlers.mirroredAnchor(id: made.key.rawValue, on: machine), let tab = anchor.pane.tabs.first(where: { $0.surface == surface }) else { throw failure }; return (anchor, tab, (key: tab.id, surface: surface))
        }
        if opened.key != tabKey { services.cloud.agentCredentials.move(chat: tabKey, to: opened.key, machine: machine.machineID) }
        timeline?.mark("open") // the chat's workspace and tab on the machine
        // From here the chat's page marks its own steps on this send's timeline (AgentTabRemoteHost.cloudSendMark).
        if let timeline { services.cloud.sendTimelines.bind(timeline, machine: daemon.machineID, tabs: [tabKey, opened.key]) }
        if let copy { services.cloud.movedChats.copied(copy) }; services.cloudStartTitles.hand(from: origin.tab, to: tab) // the chat keeps the start's title
        await AgentSessionAttachClient.trustCopiedFolder(cwd, sourceTrusted: trusted, surface: opened.surface.rawValue, ownerLink: CloudMachineLinks(appLink: machine.appLink).ownerLink, endpoint: AgentTabRemoteHost.endpoint(on: machine.daemon))
        // The agent the page's first send will start, warmed now beside the page's load and its first send (cmux#45953): after the copied folder's trust, which the daemon's prewarm checks as the start does. A background step, logged with its own time and kept off the send's steps.
        let credentials = services.agentTabs.cloudCredentials, machineID = machine.machineID, logger = services.cloud.logger, prewarmBegan = ContinuousClock.now
        CloudAgentPrewarm(cwd: cwd, harness: start.harness, model: start.model, mode: start.mode, served: daemon.supports(AgentSessionAttachClient.prewarmCapability))?
            .begin(surface: opened.surface.rawValue, endpoint: AgentTabRemoteHost.endpoint(on: daemon), ownerLink: CloudMachineLinks(appLink: machine.appLink).ownerLink,
                   permissionMode: services.agentTabs.startPermissionMode(), credentials: { (try? await credentials?.launchCredential(chat: opened.key, machine: machineID, harness: start.harness, model: start.model))?.env }) { outcome in
                logger.info("cloud start prewarm: \(outcome, privacy: .public) in \(CloudStartSteps.milliseconds(prewarmBegan.duration(to: .now)), privacy: .public) ms")
            }
        if let shown = services.agentTabs.existingView(origin.tab.id), let window = shown.window { let tabs = services.agentTabs, key = AgentTabKey(machine: machine.machineID, key: opened.key); let drawn = await AgentPaneDrawFirst.draw({ tabs.view(for: key.key, machine: key.machine) }, makeable: { [weak tabs] in tabs.map { $0.existingView(key.key, machine: key.machine) != nil || ($0.record(for: key) != nil && $0.host(for: key) != nil) } ?? true }, in: window, size: shown.frame.size); timeline?.mark(drawn.rawValue); if drawn != .painted { services.cloud.logger.notice("cloud start: chat shows before its page painted (\(drawn.rawValue, privacy: .public))") } }; if let inPlace { services.agentTabs.pageChats.cloudStarted[AgentTabKey(machine: machine.machineID, key: opened.key)] = AgentPaneCloudStarted(start: original ?? start, chat: origin.chat, workspace: origin.workspace, account: origin.account, machineID: machine.machineID); handOff(true); Self.front(inPlace, with: .init(machine: machine.machineID, key: opened.key, workspace: anchor.id), services: services); return machine.machine.title }; if let slot = origin.workspace, let window = Self.placementWindow(of: slot, services: services) { services.windows.place(newWorkspace: anchor.id, in: window, at: Self.placementSlot(besides: slot)) } // the machine's page draws out of sight first (no blink, AgentPaneView+PaintParked), then its workspace takes the row this Mac's tab started in (cmux#45947), else the top of its machine's rows, never the end (cmux#47677)
        CloudHandlers.show(anchor.id, context)
        for window in services.windows.controllers { window.state.selection.select(opened.key, in: anchor.pane.id) }
        services.agentTabs.pageChats.cloudStarted[AgentTabKey(machine: machine.machineID, key: opened.key)] = AgentPaneCloudStarted(start: original ?? start, chat: origin.chat, workspace: origin.workspace, account: origin.account, machineID: machine.machineID)
        handOff(true)
        await origin.close()
        return machine.machine.title
    }

    /// A chat with no project: nothing is read or copied; the account is checked again as above.
    private func runHome(_ start: AgentPaneCloudStart, from origin: Origin, report: @MainActor (AgentPaneCloudStart.Step) -> Void) async throws -> String {
        let tab = origin.tab
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .user), account = origin.account, start = try start.sizedForRepository(services.agentTabs.pageChats.gitHub?.sizes) // its size from the repos list
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        report(.init(name: "machine"))
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout), holding = CloudStartGate.Holding(); do {
        let (machine, plan) = try await CloudSizeLocked.naming(start.size, bytes: start.folderBytes) { try await self.machine(for: start, account: account, workspace: origin.workspace, connection: origin.connection, cli: cli, invocation: invocation, holding: holding) { await CloudChatPick(services: services).read(folder: nil, tab: tab) } }
        _ = holding.keep(machine.machineID, in: services.cloud.startGate, until: timeline); return try await plan.releasing(sameAccount: { account == services.cloud.account }, delete: { try await cli.strandThenDelete(key: start.key, account: CloudStartCore().accountText(account), machine: machine.machineID) { try await services.cloud.deleteMachine($0) } }) { // a start that can't go on deletes its machine
            try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
            // No harness login: remote approvals alone are prepared before the first prompt.
            try await RemoteApprovalPreparations.owned({ [services] in await services.cloud.restartWithApprovalsIfIdle(machine, .checkStatus) { account == services.cloud.account } }) {}
            let cwd = try await start.cloneRepository(on: .init(api: services.cloud.machineAPI, machineID: machine.machineID), machineName: machine.machine.title, size: AgentPaneCloudStart.sizeText(machine.machine.size), report: report)
            try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
            report(.init(name: "opening", machine: machine.machine.title, size: AgentPaneCloudStart.sizeText(machine.machine.size),
                         start: .init(environmentId: plan.environmentId, setup: plan.setup)))
            return try await open(start, from: origin, on: machine, cwd: cwd, tabKey: plan.tabKey)
        } } catch { holding.end(); throw error }
    }
}

/// `cmux cloud start-session --from-folder`: the folder on this Mac a session starts in a copy of, checked before any
/// machine, copied to an owned machine as the composer's Cloud start copies one, and trusted there when this Mac trusts it.
extension CloudStartChat {
    /// Cloud first use's reads and ways in (``CloudSetup``): this Mac's `_acpmux/connections`, the team's
    /// shared keys, and Settings > Cloud for the card's buttons, opened on the row that sets up what the
    /// button names (Models for Cloud: Claude, ChatGPT, API key). Lane D's `cmux.settings.models.run` takes
    /// over ``CloudSetup/run`` for Continue with ChatGPT and Set up Claude (`claudeSetupToken`), and calls
    /// ``CloudSetup/connectionsChanged()`` on every `cmux.settings.models.changed`.
    @MainActor static func wireSetup(_ services: AppServices) {
        services.cloud.setup.read = { [weak services] in
            guard let services else { return .init(personal: nil, organization: nil) }
            let personal = await QuitAgents.environment(services)?.cloudConnections()
            let keys = services.accounts.agentKeys
            guard !keys.scopeIsSignedOut else { return .init(personal: personal, organization: nil) }
            if !keys.loaded { await keys.refresh() }
            let rows = keys.currentAgents.compactMap { row in row["agent"]?.stringValue.map { (agent: $0, set: row["set"]?.boolValue == true) } }
            return .init(personal: personal, organization: keys.loaded ? CloudSetup.Snapshot.organization(keys: rows) : nil)
        }
        services.cloud.setup.gateway = { [weak services] in guard let services, !services.accounts.agentKeys.scopeIsSignedOut, let binary = services.cloud.move.cli, let team = await services.cloud.installIdentity.installTeam() else { return nil }; return await CloudMoveCLI(binary: binary).inferenceGatewayServes(team: team) } // a team in inference gateway mode, its gateway online, serves a chat with no connection of the person's own (hq#15762): the team the start's machine is made in (the install token's), whose gateway serves it, never the active team's
        services.cloud.setup.run = { [weak services] action in try? services?.settingsWindow.show(section: nil, route: DeepLink.cloudRoute(row: action.settingsRow)) }
        services.cloud.startSessionRuns.began = { [weak services] key in if key.machine.hasPrefix("name:"), let services { warmSpare(services) } } // `cmux chat --on vm:new` and `cloud start-session --name`: a create, which claims the spare, comes next
    }

    /// Warms the person's spare (``CloudSpareWarm``, no login copied), never awaited by the caller; the spare it names is keyed and linked ahead of its claim.
    @MainActor static func warmSpare(_ services: AppServices) {
        let cloud = services.cloud
        guard !services.registry.disabledFeatures.contains(.cloud), cloud.mayCallCloud, let binary = cloud.move.cli, let platform = cloud.configuration.artifactsAPIBaseURL() else { return }
        CloudSpareWarm(auth: cloud.auth, cli: CloudMoveCLI(binary: binary), platform: platform, installIdentity: cloud.installIdentity).start { [weak cloud, account = cloud.account] machine, team in if let cloud, cloud.account == account { cloud.spareReadiness.prime(machine, team: team, dials: true) } } // the spare's team as the platform names it; the reserve and the wire read the install token's (the same team), so one link is held and dialed, and the claim's record takes it
    }

    /// ``CloudSpareReadiness``'s App side: the start's own keyed restart, only on a daemon that says it is idle (no agent runs) and with `keepBusy` off, so a daemon not up yet marks nothing busy for the start's own check; the carrier the session would make.
    @MainActor static func spareReadiness(_ cloud: CloudService) -> CloudSpareReadiness.Dependencies {
        .init(scope: { [weak cloud] in cloud?.account ?? [] }, key: { [weak cloud] machine, scope in
            guard let cloud, await RemoteApprovalPreparations.shared.run(machine: machine, keepBusy: false, { [cloud, api = cloud.machineAPI] in
                guard await RemoteAgentDaemonStatus.read(cloudMachine: machine, api: api)?.idleForKeyedRestart == true, await cloud.account == scope else { return false }
                return await cloud.restartWithApprovals(machine: machine) == nil }) else { return nil }
            return AcpmuxRemotePersonKeys.shared.instance(machine: machine)
        }, keyedInstance: { AcpmuxRemotePersonKeys.shared.instance(machine: $0) }, link: { [weak cloud] machine, team in
            guard let cloud, let connector = CloudCarrierDial.Connector(machine: machine, service: .mux, cli: cloud.binary, auth: cloud.auth, platform: cloud.configuration.relayAPIBaseURL(), team: team, stateDirectory: cloud.tuiState, streams: cloud.desktopStreams) else { return nil }
            return .init(spare: connector, paths: cloud.paths)
        }, team: { [weak cloud] in await (try? cloud?.installIdentity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) }, route: { [weak cloud] machine in guard let cloud else { return nil }; return await CloudMachineRoute(api: cloud.machineAPI, machineID: machine).report() }) // the route check's report, read with no start of the machine; before it: the team the create bills (appServerCreate) and the claimed record names; never carrierTeam, the App's active team
    }
}

extension CloudStartSession {
    /// The folder's copy on the machine for a `--from-folder` run (nil without one), before the session starts in it.
    /// Only to a machine this account owns: a teammate's would keep the copy after refusing the chat.
    func copiedIfAsked(_ request: Request, to session: CloudMachineSession, account: [String?]) async throws -> (chat: String, trusted: Bool)? {
        guard let local = request.fromFolder else { return nil }
        try await Self.requireOwned(session)
        return try await copied(local, to: session, request, account: account)
    }

    /// A copy of a folder this Mac trusts is trusted there too, on the new chat tab's `surface` before its session
    /// starts, as the composer's start trusts it (the machine's agent refuses a folder it does not trust).
    static func trust(_ copy: (chat: String, trusted: Bool)?, surface: UInt64, on session: CloudMachineSession) async {
        guard let copy else { return }
        await AgentSessionAttachClient.trustCopiedFolder(copy.chat, sourceTrusted: copy.trusted, surface: surface, ownerLink: CloudMachineLinks(
            appLink: session.appLink).ownerLink, endpoint: AgentTabRemoteHost.endpoint(on: session.daemon))
    }

    /// `--from-folder` as written (`..` resolves after its symlinks), checked before anything starts: absolute, no `--cwd`, never home or a credential folder (read through realpath when it exists). Any origin, as `cloudFileWrite` (which writes any file there) takes any.
    static func fromFolder(_ invocation: ActionInvocation, cwd: String?, home: String = NSHomeDirectory()) throws -> String? {
        guard let text = invocation["fromFolder"]?.stringValue, !text.allSatisfy(\.isWhitespace) else { return nil }
        guard cwd == nil else { throw ActionFailure(message: CloudStartSessionStrings.fromFolderWithCwd) }
        guard text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }), let plain = CloudMoveFolder.normalized(text) else { throw ActionFailure(message: CloudStartSessionStrings.fromFolderInvalid) }
        if let refusal = AgentPaneCloudFolderRefusal.written(realpath(text, nil).map { path in defer { free(path) }; return String(cString: path) } ?? plain, home: home) { throw ActionFailure(message: Self.message(refusal, folder: text)) }
        return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    static func requireOwned(_ session: CloudMachineSession) async throws { if await CloudMove.ownerAnswer(session).vmKind != "owner" { throw ActionFailure(message: CloudStartSessionStrings.fromFolderNotOwned(session.machine.title)) } }

    static func message(_ refusal: AgentPaneCloudFolderRefusal, folder: String) -> String {
        switch refusal {
        case .missing: CloudStartSessionStrings.fromFolderMissing(folder)
        case .homeOrAbove: CloudStartSessionStrings.fromFolderTooBroad(folder)
        case .secret(let secret): CloudStartSessionStrings.fromFolderSecret(folder, secret: secret)
        }
    }

    /// Copies `local` to `session` exactly as the composer's Cloud start copies its chat's folder (the same check,
    /// ``AgentPaneCloudStart/checkedFolder(_:home:)``, and copy, ``CloudStartChat/copyFolder(_:key:account:to:cli:declined:failed:progress:)``),
    /// under a key of the machine and the folder, so the same command again reuses the finished copy and never pushes over
    /// what a chat changed there. Answers the chat's folder there and whether this Mac trusts the source.
    func copied(_ local: String, to session: CloudMachineSession, _ request: Request, account: [String?]) async throws -> (chat: String, trusted: Bool) {
        let name = session.machine.title, home = NSHomeDirectory()
        let checked: (folder: String, root: String)
        switch await AgentPaneCloudStart.checkedFolder(local, home: home) {
        case .success(let found): checked = found
        case .failure(let refusal): throw ActionFailure(message: Self.message(refusal, folder: local))
        }
        guard let folder = await CloudMoveFolder.read(chat: checked.folder) else { throw ActionFailure(message: CloudStartSessionStrings.fromFolderMissing(local)) }
        guard !folder.isTooBroad else { throw ActionFailure(message: CloudStartSessionStrings.fromFolderTooBroad(folder.root)) }
        // Only the working copy the check covered, as the composer's Send: a `.git` found above it since then is refused.
        let key = CloudMoveFolder.copyKey(machine: session.machineID, folder: checked.folder)
        var start = AgentPaneCloudStart(task: "", cwd: checked.folder, key: key)
        start.uploadRoot = checked.root
        guard start.uploads(folder) else { throw ActionFailure(message: CloudStartSessionStrings.fromFolderMissing(local)) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        try Self.checked(account, now: services.cloud.account, request.asked(machine: name))
        // A refused git seed copies the folder as the composer's start does; a copy the machine's disk cannot hold
        // refuses the start with its reason (CloudSeedRefusal).
        struct Declined: Error { let reason: String }
        let asked = request.asked(machine: name)
        let copy: CloudStartChat.Copied
        do {
            copy = try await CloudStartChat(services: services).copyFolder(
                folder, key: key, account: account, to: session, cli: CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout),
                declined: { Declined(reason: $0.tooLarge) }, failed: { $0 }) { _ in }
        } catch let declined as Declined {
            throw ActionFailure(message: declined.reason)
        } catch {
            try Self.failed(account, now: services.cloud.account, asked, await CloudMoveFolder.isFolder(folder.root) ? CloudMoveStrings.syncFailed(name, CloudStrings.errorText(error)) : CloudStartSessionStrings.fromFolderMissing(local))
        }
        guard copy.0.ok else { throw ActionFailure(message: await CloudMoveFolder.isFolder(folder.root) ? CloudMoveFailure.syncing(copy.0, machine: name, retry: .move(machineID: session.machineID)).message : CloudStartSessionStrings.fromFolderMissing(local)) }
        return (copy.1.chat, copy.1.sourceTrusted)
    }
}

extension CloudStartRunKey {
    /// The run of `request` asked by chat `caller` (nil: a person's or a script's) in `account`.
    init(_ request: CloudStartSession.Request, caller: String?, account: [String?]) {
        self.init(machine: request.machineID.map { "id:" + $0 } ?? "name:" + (request.name ?? ""), agent: request.agent, cwd: request.cwd,
                  caller: caller, account: account, fromFolder: request.fromFolder, model: request.model)
    }
}
