import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
// Re-exported: every App file and `@testable import CmuxNextApp` test reads Cloud's start-session strings (CloudStartSessionStrings).
@_exported import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextRemote
import CmuxNextTabs
import Foundation

/// A new chat's first send with Cloud picked as where it runs (`cloud.startChat`,
/// ``AgentPaneCloudStart``; leo-workspace design/cloud-work-mode.md): the chat goes to Cloud with no
/// machine, size or environment prompt. It takes a free Cloud machine of this person's, else a new
/// one for chats sized for the chat by ``CloudChatPick`` (``machine(for:account:workspace:cli:invocation:pick:)``),
/// copies the chat's folder to a folder of the send's own there, and opens a new chat on that machine in the
/// copied folder whose first prompt is the person's (a seeded prompt, sent once with the Send's
/// gesture, as onboarding's first task). This Mac's tab, which never started a chat, then closes.
///
/// The page's card shows progress and failures; nothing moves, so no Move to Cloud toast (Leo, 2026-11-04: "why is this showing up when i create a new chat").
/// Not behind Labs: it needs Cloud allowed and a signed-in account (``refusal(_:)``). A chat with no
/// project (``AgentPaneCloudStart/home``) copies nothing and opens in the machine's own folder.
@MainActor
struct CloudStartChat {
    let services: AppServices
    /// Where the start's questions show (its first login, the login copy consent, Codex's sign-in): the
    /// sending pane's card for a composer start; nil asks in a dialog on the active window.
    var asker: AgentPaneCloudAsker?

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
            return await CloudStartChat(services: services, asker: .card(view, start: start.key)).reply(start, tab: tab) { [weak view] step in
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
            let account = services.cloud.account
            let origin = Origin(tab: tab, chat: start.cwd ?? tab.cwd, workspace: services.workspaceID(ofTab: tab.id), account: account) { [services] in
                // This Mac's tab, which never started a chat: the chat is the machine's now.
                do {
                    try await services.daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
                } catch {
                    services.cloud.logger.error("cloud start chat: closing this Mac's tab failed: \(String(describing: error), privacy: .public)")
                }
            }
            let machine = try await run(start, from: origin, report: report)
            return AgentPaneReply.success(["machine": machine])
        } catch is CloudMoveFolder.Gone { // the card's own words, with no Retry: picking another folder is the way on
            return AgentPaneCloudFolderRefusal.missing.reply
        } catch is CloudMachineCap.RunHere { // the cap card's Run on This Mac: the page sends it here (cloudRun.ts)
            return AgentPaneReply.failure(code: CloudMachineCap.runHereCode, message: CloudMachineCap.runHereCode)
        } catch {
            let message = (error as? CloudMove.Failure)?.message ?? (error as? ActionFailure)?.message
                ?? CloudMoveStrings.moveFailed(CloudStrings.errorText(error))
            services.cloud.logger.error("cloud start chat failed: \(message, privacy: .public)")
            // A failure a retry can help gets the card's Retry; a plan refusal keeps its code and the teams (CloudStartView).
            let plan = CloudMachineCreation.proRefusal(error) != nil
            return AgentPaneReply.failure(code: plan ? "cloud_plan_required" : "cloud_start_failed", message: message, details: plan ? services.cloud.auth.planRefusalTeams : nil, retryable: (error as? CloudMove.Failure)?.retry != nil, origin: "native")
        }
    }

    /// Why no Cloud chat can start at all now, the sandbox's codes (`AgentPageChats.wireSandbox`):
    /// Cloud off by policy, or not signed in. Either link takes the start: the Cloud app server's
    /// carrier socket serves each connection as its own dial of the machine's daemon, so the copy's
    /// CLI gets a connection beside the app's (``CloudMove/connected(_:_:)``). Not behind Labs (Leo,
    /// 2026-10-30: "that seems dumb. i dont like putting so much stuff in labs"): the person picked
    /// Cloud for this send.
    static func refusal(_ services: AppServices) -> String? {
        refusal(cloudDisabled: services.registry.disabledFeatures.contains(.cloud) || !services.cloud.mayCallCloud,
                signedIn: services.cloud.isSignedIn)
    }

    nonisolated static func refusal(cloudDisabled: Bool, signedIn: Bool) -> String? { // the rule: cmux-cloud-start-core `start`
        CloudStartCore().refusal(cloudDisabled: cloudDisabled, signedIn: signedIn)
    }

    /// Where a start comes from: the tab that sent (this Mac's new tab, or for a repick the chat's tab on
    /// the machine it was on), the chat's folder on this Mac, the Mac workspace and account the send
    /// began in, and what closes the tab once the chat opened on its machine.
    struct Origin {
        let tab: TabModel
        let chat: String?
        let workspace: String?
        let account: [String?]
        let close: @MainActor () async -> Void
    }

    /// The start; returns the machine's name.
    func run(_ start: AgentPaneCloudStart, from origin: Origin, report: @MainActor (AgentPaneCloudStart.Step) -> Void) async throws -> String {
        let tab = origin.tab
        guard !start.home else { return try await runHome(start, from: origin, report: report) }
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
        let folderName = URL(fileURLWithPath: chat).lastPathComponent
        report(.init(name: "machine", folder: folderName))
        // The machine, the pin and the keys are cmux-tui's (`cmux link start-chat`, +Machine).
        let account = origin.account
        let (machine, plan) = try await self.machine(for: start, account: account, workspace: origin.workspace, cli: cli, invocation: invocation) {
            await CloudChatPick(services: services).read(folder: chat, tab: tab)
        }
        let name = machine.machine.title, again = CloudMoveRetries.Retry.move(machineID: machine.machineID)
        // The account may have changed while the machine connected: copy nothing then.
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        // The chat's harness login (DEV and dogfood builds, +Login) and remote approvals run beside the copy, awaited before the chat opens.
        let size = AgentPaneCloudStart.sizeText(machine.machine.size)
        let copy: Copied = try await RemoteApprovalPreparations.owned({ [services] in await services.cloud.restartWithApprovalsIfIdle(machine, .checkStatus) { account == services.cloud.account } }) {
            async let loginPassed = passHarnessLogin(harness: start.harness, machine: machine)
            report(.init(name: "folder", folder: folderName, machine: name, size: size))
            guard await CloudMoveFolder.isFolder(folder.root) else { throw CloudMoveFolder.Gone() } // removed while the machine came up
            // Each copy goes to a new folder of the send's own, under its account as its pin; a retry whose
            // copy finished opens its chat without copying again, which would overwrite what it changed.
            let copy: Copied
            do {
                copy = try await copyFolder(folder, key: start.key, account: account, to: machine, cli: cli) {
                    report(AgentPaneCloudStart.copying($0, folder: folderName, machine: name, size: size))
                }
            } catch {
                // Timed out or didn't launch: Retry copies again on this machine, into a new folder.
                throw await CloudMoveFolder.orGone(CloudMove.Failure(message: CloudMoveStrings.syncFailed(name, CloudStrings.errorText(error)), retry: again), root: folder.root)
            }
            report(.init(name: "folder", folder: folderName, machine: name, size: size,
                         cloneState: copy.0.seedState, clonePhase: copy.0.seedPhase,
                         cloneStartedAt: copy.0.seedStartedAt, cloneFinishedAt: copy.0.seedFinishedAt,
                         start: .init(environmentId: plan.environmentId, setup: plan.setup)))
            guard copy.0.ok else { throw await CloudMoveFolder.orGone(CloudMoveFailure.syncing(copy.0, machine: name, retry: again), root: folder.root) }
            // The copy may take long: a chat whose account changed meanwhile opens nowhere, and this Mac's tab stays.
            try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
            _ = await loginPassed
            return copy
        }
        // The login may have waited on a confirm and a sign-in: check the account again after it.
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        report(.init(name: "opening", folder: folderName, machine: name, size: size,
                     start: .init(environmentId: plan.environmentId, setup: plan.setup)))
        let entry = AgentTabStore.registryHost(of: machine.daemon).map {
            CloudMovedChats.Entry(machineID: machine.machineID, host: $0, session: "", harness: start.harness,
                                  localRoot: folder.root, localChat: chat, remoteFolder: copy.1.folder, remoteChat: copy.1.chat)
        }
        return try await open(start, from: origin, on: machine, cwd: copy.1.chat, trusted: copy.1.sourceTrusted, tabKey: plan.tabKey, targetPane: plan.targetPane, cli: cli, copy: entry)
    }

    /// What a copy answers: the CLI's answer, and the chat's folder and the copied folder on the machine, whether
    /// it copied now (false: an earlier copy under the key finished) and whether this Mac trusts the source.
    typealias Copied = (CloudMoveCLI.Answer, (chat: String, folder: String, copied: Bool, sourceTrusted: Bool))

    /// Copies `folder` to a new folder of the start's own on `machine` (`cmux link start-chat copy`), under `key` and
    /// `account` as its pin: the composer's Cloud start and `cmux cloud start-session --from-folder` alike
    /// (``CloudStartSession``). A start whose copy under `key` already finished on `machine` gets that copy's folder,
    /// never copied again: that would overwrite what its chat changed. `progress` gets the copy's progress lines.
    func copyFolder(_ folder: CloudMoveFolder, key: String, account: [String?], to machine: CloudMachineSession, cli: CloudMoveCLI,
                    progress: (SeedProgress) -> Void) async throws -> Copied {
        let name = machine.machine.title, storeAccess = await services.cloud.auth.startChatStoreAccess(account: account)
        // A machine whose older cmux-tui refuses the copy is updated to this app's build, then copied again on its new link (CloudOutdatedMachine);
        // the copy's progress lines go to the clone row as they come, about 4 a second (SeedProgress.feed).
        return try await CloudOutdatedMachine.copy(socket: { await machine.daemon.connection?.endpoint?.socketPath },
                                                   link: { CloudMachineUpdates.handshake(machine, machines: services.machines) },
                                                   notConnected: CloudMove.Failure(message: CloudMoveStrings.notConnected(name))) { socket in try await SeedProgress.feed({ [cli, key, owner = CloudStartCore().accountText(account), id = machine.machineID, root = folder.root, sub = folder.subpath, roots = services.cloud.move.workRoots, home = QuitAgents.environment(services)?.home.path, storeAccess] line in
                try await cli.startChatCopy(key: key, account: owner, machine: id, socket: socket, local: root, subpath: sub, workRoots: roots, acpmuxHome: home, access: storeAccess, stderrLine: line)
            }, each: progress)
        } answer: { ($0.0.ok, $0.0.errorCode, $0.0.side) } update: { await CloudMachineUpdates.updateNow(machine.machineID, services: services) }
    }

    /// Opens the chat on `machine` in `cwd` under the plan's `tabKey` (a retry gets the same tab) and closes
    /// the origin's tab: the chat is the machine's now. A copy of a folder this Mac trusts (`trusted`) is trusted
    /// there first. The opened tab is kept with its start, so another machine picked before its first send runs
    /// moves it there (+Repick).
    func open(_ start: AgentPaneCloudStart, from origin: Origin, on machine: CloudMachineSession, cwd: String?,
              trusted: Bool = false, tabKey: String, targetPane: String? = nil, cli: CloudMoveCLI, copy: CloudMovedChats.Entry? = nil) async throws -> String {
        guard !start.attachments.isEmpty else { return try await openUploaded(start, from: origin, on: machine, cwd: cwd, trusted: trusted, tabKey: tabKey, targetPane: targetPane, cli: cli, copy: copy) }
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
            return try await openUploaded(uploaded, from: origin, on: machine, cwd: cwd, trusted: trusted, tabKey: tabKey, targetPane: targetPane, cli: cli, copy: copy, original: start)
        }
    }

    private func openUploaded(_ start: AgentPaneCloudStart, from origin: Origin, on machine: CloudMachineSession, cwd: String?,
                              trusted: Bool, tabKey: String, targetPane: String?, cli: CloudMoveCLI, copy: CloudMovedChats.Entry? = nil,
                              original: AgentPaneCloudStart? = nil) async throws -> String {
        await CloudOutdatedMachine.updateBeforeUsingCapability(
            holds: { services.agentTabs.holdsTabs(machine.daemon) },
            update: { await CloudMachineUpdates.updateNow(machine.machineID, services: services) })
        let context = AppActionContext(services: services)
        let anchor: (id: String, key: WorkspaceKey, pane: PaneModel)
        if let targetPane {
            _ = try await CloudMachineWorkspace.existing(in: machine.daemon.store, notConnected: CloudMove.Failure(message: CloudMoveStrings.notConnected(machine.machine.title)))
            guard let found = CloudMachineWorkspace.targetAnchor(targetPane, in: machine.daemon.store) else {
                throw CloudMove.Failure(message: CloudMoveStrings.notConnected(machine.machine.title))
            }
            anchor = found
        } else {
            anchor = try await CloudHandlers.terminalAnchor(on: machine, context)
            guard let pane = anchor.pane.resourceID?.rawValue else {
                throw CloudMove.Failure(message: CloudMoveStrings.notConnected(machine.machine.title))
            }
            _ = try Self.checked(await cli.startChatTargetPane(key: start.key, account: CloudStartCore().accountText(origin.account), machine: machine.machineID, pane: pane))
        }
        if let copy { services.cloud.movedChats.copied(copy) }
        let (seed, handOff) = AgentPaneSeedSource.handingOffDraft(start.seed(cwd: cwd)) { [services] in services.agentTabs.unsentDrafts.draft(forTab: services.agentTabs.resolve(origin.tab.id), machine: services.agentTabs.daemonListing(origin.tab)?.machineID) }
        defer { handOff(false) }
        let pending = try services.agentTabs.open(in: anchor.pane.handle, of: machine.daemon, seed: seed, idempotencyKey: tabKey)
        let opened = try await pending.value()
        await AgentSessionAttachClient.trustCopiedFolder(cwd, sourceTrusted: trusted, surface: opened.surface.rawValue, ownerLink: CloudMachineLinks(appLink: machine.appLink).ownerLink, endpoint: AgentTabRemoteHost.endpoint(on: machine.daemon))
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
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .user), account = origin.account
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        report(.init(name: "machine"))
        let (machine, plan) = try await self.machine(for: start, account: account, workspace: origin.workspace,
                                                     cli: CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout), invocation: invocation) { await CloudChatPick(services: services).read(folder: nil, tab: tab) }
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        // The harness login before the first prompt, as for a chat with a project (+Login), and remote approvals meanwhile.
        _ = try await RemoteApprovalPreparations.owned({ [services] in await services.cloud.restartWithApprovalsIfIdle(machine, .checkStatus) { account == services.cloud.account } }) { await passHarnessLogin(harness: start.harness, machine: machine) }
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        report(.init(name: "opening", machine: machine.machine.title, size: AgentPaneCloudStart.sizeText(machine.machine.size),
                     start: .init(environmentId: plan.environmentId, setup: plan.setup)))
        return try await open(start, from: origin, on: machine, cwd: nil, tabKey: plan.tabKey, targetPane: plan.targetPane,
                              cli: CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout))
    }
}

/// `cmux cloud start-session --from-folder`: the folder on this Mac a session starts in a copy of, checked before any
/// machine, copied to an owned machine as the composer's Cloud start copies one, and trusted there when this Mac trusts it.
extension CloudStartSession {
    /// The words a refused harness login gets (the strings module doesn't know the login's own reasons).
    static func loginRefusal(_ refusal: CloudHarnessLoginDecision.Reason) -> CloudStartSessionStrings.LoginRefusal {
        refusal == .machineLoginMissing ? .machineLoginMissing : refusal == .consentFirst ? .consentFirst : .loginNeeded
    }

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
    /// ``AgentPaneCloudStart/checkedFolder(_:home:)``, and copy, ``CloudStartChat/copyFolder(_:key:account:to:cli:progress:)``),
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
        let copy: CloudStartChat.Copied
        do {
            copy = try await CloudStartChat(services: services).copyFolder(folder, key: key, account: account, to: session,
                                                                          cli: CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)) { _ in }
        } catch {
            try Self.failed(account, now: services.cloud.account, request.asked(machine: name), await CloudMoveFolder.isFolder(folder.root) ? CloudMoveStrings.syncFailed(name, CloudStrings.errorText(error)) : CloudStartSessionStrings.fromFolderMissing(local))
        }
        guard copy.0.ok else { throw ActionFailure(message: await CloudMoveFolder.isFolder(folder.root) ? CloudMoveFailure.syncing(copy.0, machine: name, retry: .move(machineID: session.machineID)).message : CloudStartSessionStrings.fromFolderMissing(local)) }
        return (copy.1.chat, copy.1.sourceTrusted)
    }
}

extension CloudStartRunKey {
    /// The run of `request` asked by chat `caller` (nil: a person's or a script's) in `account`.
    init(_ request: CloudStartSession.Request, caller: String?, account: [String?]) {
        self.init(machine: request.machineID.map { "id:" + $0 } ?? "name:" + (request.name ?? ""), agent: request.agent, cwd: request.cwd,
                  caller: caller, account: account, login: request.login.requested?.rawValue, fromFolder: request.fromFolder, model: request.model)
    }
}
