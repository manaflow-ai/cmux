import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
// Re-exported: every App file and `@testable import CmuxNextApp` test reads Cloud's start-session strings (CloudStartSessionStrings).
@_exported import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
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
    /// Where the start's questions show: the sending pane's card for a composer start; nil asks in a
    /// dialog on the active window.
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

    /// The page's reply: success with the machine's name, or a refusal in the person's words. The card
    /// says a failure, with Retry when another try can help (the same start again under its key, so a
    /// machine already made or a folder already copied is reused): no toast.
    /// `report` tells the page's card each step as it begins (``AgentPaneCloudStart/progress(_:folder:machine:size:to:)``).
    func reply(_ start: AgentPaneCloudStart, tab: TabModel, report: @MainActor (AgentPaneCloudStart.Step) -> Void = { _ in }) async -> [String: Any] {
        if let refusal = Self.refusal(services) {
            return AgentPaneReply.failure(code: refusal, message: Self.refusalMessage(refusal))
        }
        do {
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
        } catch is CloudMachineCap.RunHere { // the cap card's Run on This Mac: the page sends it here (cloudRun.ts)
            return AgentPaneReply.failure(code: CloudMachineCap.runHereCode, message: CloudMachineCap.runHereCode)
        } catch {
            let message = (error as? CloudMove.Failure)?.message ?? (error as? ActionFailure)?.message
                ?? CloudMoveStrings.moveFailed(CloudStrings.errorText(error))
            services.cloud.logger.error("cloud start chat failed: \(message, privacy: .public)")
            // A failure a retry can help (the machine didn't connect, a copy that timed out) gets the card's Retry (cloudRun.ts
            // `cloudStartKeys`); a plan refusal keeps its own code, so the card offers Upgrade or This Mac (CloudStartView).
            return AgentPaneReply.failure(code: CloudMachineCreation.proRefusal(error) == nil ? "cloud_start_failed" : "cloud_plan_required", message: message, details: nil, retryable: (error as? CloudMove.Failure)?.retry != nil, origin: "native")
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

    /// Keep the stable refusal code for bridge callers, but give the Cloud
    /// start card actionable copy for a signed-out first send.
    nonisolated static func refusalMessage(_ code: String) -> String {
        code == "not_signed_in" ? CloudStrings.signInFirst : code
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
        // No login step: the machine's agents reach models through its edge (the Cloud service's model
        // route), and this Mac copies no provider login to it.
        let size = AgentPaneCloudStart.sizeText(machine.machine.size)
        report(.init(name: "folder", folder: folderName, machine: name, size: size))
        // Each copy goes to a new folder of the send's own, under its account as its pin; a retry whose
        // copy finished opens its chat without copying again, which would overwrite what it changed.
        // A refused git seed asks "Copy the folder to <machine>?" first (CloudSeedRefusal): Cancel keeps Retry on this machine.
        let copy = try await copyFolder(folder, key: start.key, account: account, to: machine, cli: cli,
                                        declined: { CloudMove.Failure(message: $0, retry: again) },
                                        // Timed out or didn't launch: Retry copies again on this machine, into a new folder.
                                        failed: { CloudMove.Failure(message: CloudMoveStrings.syncFailed(name, CloudStrings.errorText($0)), retry: again) }) {
            report(AgentPaneCloudStart.copying($0, folder: folderName, machine: name, size: size))
        }
        report(.init(name: "folder", folder: folderName, machine: name, size: size,
                     cloneState: copy.0.seedState, clonePhase: copy.0.seedPhase,
                     cloneStartedAt: copy.0.seedStartedAt, cloneFinishedAt: copy.0.seedFinishedAt,
                     start: .init(environmentId: plan.environmentId, setup: plan.setup)))
        guard copy.0.ok else { throw CloudMove.failure(syncing: copy.0, machine: name, retry: again) }
        // The copy may take long: a chat whose account changed meanwhile opens nowhere, and this Mac's tab stays.
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
    /// A machine that can't clone the folder from its git remote asks the person before the whole folder is copied
    /// (``CloudSeedRefusal``); their Cancel throws `declined(reason)`. A copy that times out or doesn't launch throws `failed(error)`.
    func copyFolder(_ folder: CloudMoveFolder, key: String, account: [String?], to machine: CloudMachineSession, cli: CloudMoveCLI,
                    declined: (String) -> any Error, failed: (any Error) -> any Error,
                    progress: (SeedProgress) -> Void) async throws -> Copied {
        let name = machine.machine.title, storeAccess = await services.cloud.auth.startChatStoreAccess(account: account)
        // A machine whose older cmux-tui refuses the copy is updated to this app's build, then copied again on its new link (CloudOutdatedMachine);
        // the copy's progress lines go to the clone row as they come, about 4 a second (SeedProgress.feed).
        return try await CloudSeedRefusal.copying(machine: name, in: { services.windows.active?.window }, declined: declined) { refusal in do {
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
        let pending = try services.agentTabs.open(in: anchor.pane.handle, of: machine.daemon, seed: AgentPaneSeedSource(start.seed(cwd: cwd)),
                                                 idempotencyKey: tabKey)
        let opened = try await pending.value()
        await AgentSessionAttachClient.trustCopiedFolder(cwd, sourceTrusted: trusted, surface: opened.surface.rawValue, ownerLink: CloudMachineLinks(
            appLink: machine.appLink).ownerLink, endpoint: AgentTabRemoteHost.endpoint(on: machine.daemon))
        CloudHandlers.show(anchor.id, context)
        for window in services.windows.controllers { window.state.selection.select(opened.key, in: anchor.pane.id) }
        services.agentTabs.pageChats.cloudStarted[AgentTabKey(machine: machine.machineID, key: opened.key)] = AgentPaneCloudStarted(start: original ?? start, chat: origin.chat, workspace: origin.workspace,
                                                                                                                               account: origin.account, machineID: machine.machineID)
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
        report(.init(name: "opening", machine: machine.machine.title, size: AgentPaneCloudStart.sizeText(machine.machine.size),
                     start: .init(environmentId: plan.environmentId, setup: plan.setup)))
        return try await open(start, from: origin, on: machine, cwd: nil, tabKey: plan.tabKey, targetPane: plan.targetPane,
                              cli: CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout))
    }
}

/// `cmux cloud start-session --from-folder`: the folder on this Mac a session starts in a copy of, checked before any
/// machine, copied to an owned machine as the composer's Cloud start copies one, and trusted there when this Mac trusts it.
extension CloudStartChat {
    /// Warms the person's spare (``CloudSpareWarm``, no login copied), never awaited by the caller.
    @MainActor static func warmSpare(_ services: AppServices) {
        let cloud = services.cloud
        guard !services.registry.disabledFeatures.contains(.cloud), cloud.mayCallCloud, let binary = cloud.move.cli, let platform = cloud.configuration.artifactsAPIBaseURL() else { return }
        CloudSpareWarm(auth: cloud.auth, cli: CloudMoveCLI(binary: binary), platform: platform, installIdentity: cloud.installIdentity).start()
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

    /// `--from-folder`, checked before anything starts: absolute, no `--cwd`, never home or a credential folder. Any origin, as `cloudFileWrite` (which writes any file there) takes any.
    static func fromFolder(_ invocation: ActionInvocation, cwd: String?, home: String = NSHomeDirectory()) throws -> String? {
        guard let text = invocation["fromFolder"]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard cwd == nil else { throw ActionFailure(message: CloudStartSessionStrings.fromFolderWithCwd) }
        guard text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }), let folder = CloudMoveFolder.normalized(text) else { throw ActionFailure(message: CloudStartSessionStrings.fromFolderInvalid) }
        if let refusal = AgentPaneCloudFolderRefusal.written(folder, home: home) { throw ActionFailure(message: Self.message(refusal, folder: folder)) }
        return folder
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
            try Self.failed(account, now: services.cloud.account, request.asked(machine: name), CloudMoveStrings.syncFailed(name, CloudStrings.errorText(error)))
        }
        guard copy.0.ok else { throw ActionFailure(message: CloudMove.failure(syncing: copy.0, machine: name, retry: .move(machineID: session.machineID)).message) }
        return (copy.1.chat, copy.1.sourceTrusted)
    }
}

extension CloudStartRunKey {
    /// The run of `request` asked by chat `caller` (nil: a person's or a script's) in `account`.
    init(_ request: CloudStartSession.Request, caller: String?, account: [String?]) {
        self.init(machine: request.machineID.map { "id:" + $0 } ?? "name:" + (request.name ?? ""), agent: request.agent, cwd: request.cwd,
                  caller: caller, account: account, fromFolder: request.fromFolder)
    }
}
