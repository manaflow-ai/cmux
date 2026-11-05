import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
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

    /// The page's runner for every pane (``AgentPageChats/seed(_:)``): `view` is the pane that sent.
    static func runner(_ tabs: AgentTabStore, services: AppServices) -> @MainActor (AgentPaneView?, AgentPaneCloudStart) async -> [String: Any] {
        { [weak tabs, weak services] view, start in
            guard let services else { return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled") }
            // Only a tab of this Mac's daemon: the folder it names is copied from this Mac.
            guard let view, let key = tabs?.views.first(where: { $0.value === view })?.key, let (tab, _) = services.locateTab(key),
                  services.machines.daemon(forTab: tab).isLocal else {
                return AgentPaneReply.failure(code: "unavailable", message: CloudMoveStrings.notAChat)
            }
            return await CloudStartChat(services: services).reply(start, tab: tab) { [weak view] step in
                if let view { start.progress(step, to: view) }
            }
        }
    }

    /// The page's reply: success with the machine's name, or a refusal in the person's words. `retried`: Retry's start, no card waits for it.
    /// `report` tells the page's card each step as it begins (``AgentPaneCloudStart/progress(_:folder:machine:size:to:)``).
    func reply(_ start: AgentPaneCloudStart, tab: TabModel, retried: Bool = false, report: @MainActor (AgentPaneCloudStart.Step) -> Void = { _ in }) async -> [String: Any] {
        if let refusal = Self.refusal(services) {
            return AgentPaneReply.failure(code: refusal, message: Self.refusalMessage(refusal))
        }
        let toastID = "cloud-start-" + tab.id
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
            CmuxToastCenter.shared.close(id: toastID) // an earlier try's Retry toast, in every window
            return AgentPaneReply.success(["machine": machine])
        } catch is CloudMachineCap.RunHere { // the cap card's Run on This Mac: the page sends it here (cloudRun.ts)
            CmuxToastCenter.shared.close(id: toastID) // every window: the start may have begun in one no longer in front
            return AgentPaneReply.failure(code: CloudMachineCap.runHereCode, message: CloudMachineCap.runHereCode)
        } catch {
            let message = (error as? CloudMove.Failure)?.message ?? (error as? ActionFailure)?.message
                ?? CloudMoveStrings.moveFailed(CloudStrings.errorText(error))
            services.cloud.logger.error("cloud start chat failed: \(message, privacy: .public)")
            // A failure a retry can help (the machine didn't connect, a copy that timed out) offers Retry: the
            // same start again under its key, so a machine already made or a folder already copied is reused.
            var retry: (@MainActor () -> Void)?
            if (error as? CloudMove.Failure)?.retry != nil {
                let tabID = tab.id
                retry = { [weak services] in
                    // The tab is found again by id: a tab closed since then retries nothing.
                    guard let services, let (tab, _) = services.locateTab(tabID) else { return }
                    // task-owner: one retried start; it ends with the chat opening or its own failure toast
                    _ = Task { _ = await CloudStartChat(services: services).reply(start, tab: tab, retried: true) }
                }
            }
            // The card says the failure; a toast only where Retry lives, or for a retry no card waits for.
            if retry != nil || retried { CloudMove.toast(services, toastID, message, duration: .seconds(retry == nil ? 12 : 30), retry: retry) } else { CmuxToastCenter.shared.close(id: toastID) }
            return AgentPaneReply.failure(code: "cloud_start_failed", message: message)
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
        // The chat's harness login (DEV and dogfood builds, +Login): it runs alongside the copy and is
        // awaited before the chat opens, so its first prompt starts signed in. It never fails the start.
        async let loginPassed = passHarnessLogin(harness: start.harness, machine: machine)
        let size = AgentPaneCloudStart.sizeText(machine.machine.size)
        report(.init(name: "folder", folder: folderName, machine: name, size: size))
        // Each copy goes to a new folder of the send's own, under its account as its pin; a retry whose
        // copy finished opens its chat without copying again, which would overwrite what it changed.
        let copy: (CloudMoveCLI.Answer, (chat: String, folder: String, copied: Bool, sourceTrusted: Bool)), storeAccess = await services.cloud.auth.startChatStoreAccess(account: account)
        do {
            // A machine whose older cmux-tui refuses the copy is updated to this app's build, then copied again on its new link (CloudOutdatedMachine);
            // the copy's progress lines go to the clone row as they come, about 4 a second (SeedProgress.feed).
            copy = try await CloudOutdatedMachine.copy(socket: { await machine.daemon.connection?.endpoint?.socketPath },
                                                       link: { CloudMachineUpdates.handshake(machine, machines: services.machines) },
                                                       notConnected: CloudMove.Failure(message: CloudMoveStrings.notConnected(name))) { socket in try await SeedProgress.feed({ [cli, key = start.key, owner = CloudStartCore().accountText(account), id = machine.machineID, root = folder.root, sub = folder.subpath, roots = services.cloud.move.workRoots, home = QuitAgents.environment(services)?.home.path, storeAccess] line in
                    try await cli.startChatCopy(key: key, account: owner, machine: id, socket: socket, local: root, subpath: sub, workRoots: roots, acpmuxHome: home, access: storeAccess, stderrLine: line)
                }) { report(AgentPaneCloudStart.copying($0, folder: folderName, machine: name, size: size)) }
            } answer: { ($0.0.ok, $0.0.errorCode, $0.0.side) } update: { await CloudMachineUpdates.updateNow(machine.machineID, services: services) }
        } catch {
            // Timed out or didn't launch: Retry copies again on this machine, into a new folder.
            throw CloudMove.Failure(message: CloudMoveStrings.syncFailed(name, CloudStrings.errorText(error)), retry: again)
        }
        report(.init(name: "folder", folder: folderName, machine: name, size: size,
                     cloneState: copy.0.seedState, clonePhase: copy.0.seedPhase,
                     cloneStartedAt: copy.0.seedStartedAt, cloneFinishedAt: copy.0.seedFinishedAt,
                     start: .init(environmentId: plan.environmentId, setup: plan.setup)))
        guard copy.0.ok else { throw CloudMove.failure(syncing: copy.0, machine: name, retry: again) }
        // The copy may take long: a chat whose account changed meanwhile opens nowhere, and this Mac's tab stays.
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        _ = await loginPassed
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

    /// Opens the chat on `machine` in `cwd` under the plan's `tabKey` (a retry gets the same tab) and closes
    /// the origin's tab: the chat is the machine's now. A copy of a folder this Mac trusts (`trusted`) is trusted
    /// there first. The opened tab is kept with its start, so another machine picked before its first send runs
    /// moves it there (+Repick).
    func open(_ start: AgentPaneCloudStart, from origin: Origin, on machine: CloudMachineSession, cwd: String?,
              trusted: Bool = false, tabKey: String, targetPane: String? = nil, cli: CloudMoveCLI, copy: CloudMovedChats.Entry? = nil) async throws -> String {
        guard !start.attachments.isEmpty else { return try await openUploaded(start, from: origin, on: machine, cwd: cwd, trusted: trusted, tabKey: tabKey, targetPane: targetPane, cli: cli, copy: copy) }
        await CloudOutdatedMachine.updateBeforeUsingCapability(holds: { machine.daemon.supports(DaemonCapability.agentSessionContent.rawValue) }, update: { await CloudMachineUpdates.updateNow(machine.machineID, services: services) })
        guard machine.daemon.supports(DaemonCapability.agentSessionContent.rawValue), let carry = AgentPaneCloudAttachments(start.attachments), let pastes = CloudUploads.pastes,
              let binary = services.cloud.move.cli, let socket = await machine.daemon.connection?.endpoint?.socketPath,
              let root = cwd.flatMap({ CloudAccessAsks.remoteRoot($0, roots: services.cloud.move.workRoots) }) ?? services.cloud.move.workRoots.first else { throw CloudMove.Failure(message: CloudUploadStrings.failed) }
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
        services.agentTabs.pageChats.cloudStarted[opened.key] = AgentPaneCloudStarted(start: original ?? start, chat: origin.chat, workspace: origin.workspace,
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
        // The harness login before the first prompt, as for a chat with a project (+Login).
        _ = await passHarnessLogin(harness: start.harness, machine: machine)
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        report(.init(name: "opening", machine: machine.machine.title, size: AgentPaneCloudStart.sizeText(machine.machine.size),
                     start: .init(environmentId: plan.environmentId, setup: plan.setup)))
        return try await open(start, from: origin, on: machine, cwd: nil, tabKey: plan.tabKey, targetPane: plan.targetPane,
                              cli: CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout))
    }
}
