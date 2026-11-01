import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// A new chat's first send with Cloud picked as where it runs (`cloud.startChat`,
/// ``AgentPaneCloudStart``; leo-workspace design/cloud-work-mode.md): the chat goes to Cloud with no
/// machine, size or environment prompt. It takes a free Cloud machine of this person's, else a new
/// one for chats sized for the chat by ``CloudChatPick`` (``machine(for:account:cli:invocation:pick:)``),
/// copies the chat's folder to a folder of the send's own there, and opens a new chat on that machine in the
/// copied folder whose first prompt is the person's (a seeded prompt, sent once with the Send's
/// gesture, as onboarding's first task). This Mac's tab, which never started a chat, then closes.
///
/// Progress and failures are Move to Cloud's toasts, and the page gets the failure's message.
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

    /// The page's reply: success with the machine's name, or a refusal in the person's words.
    /// `report` tells the page's card each step as it begins (``AgentPaneCloudStart/progress(_:folder:machine:size:to:)``).
    func reply(_ start: AgentPaneCloudStart, tab: TabModel, report: @MainActor (AgentPaneCloudStart.Step) -> Void = { _ in }) async -> [String: Any] {
        if let refusal = Self.refusal(services) { return AgentPaneReply.failure(code: refusal, message: refusal) }
        let toastID = "cloud-start-" + tab.id
        CloudMove.toast(services, toastID, CloudMoveStrings.moving, duration: .seconds(600))
        do {
            let machine = try await run(start, tab: tab, report: report)
            CloudMove.toast(services, toastID, CloudMoveStrings.moved(machine), duration: .seconds(6))
            return AgentPaneReply.success(["machine": machine])
        } catch {
            let message = (error as? CloudMove.Failure)?.message ?? (error as? ActionFailure)?.message
                ?? CloudMoveStrings.moveFailed(CloudStrings.errorText(error))
            services.cloud.logger.error("cloud start chat failed: \(message, privacy: .public)")
            CloudMove.toast(services, toastID, message, duration: .seconds(12))
            return AgentPaneReply.failure(code: "cloud_start_failed", message: message)
        }
    }

    /// Why no Cloud chat can start at all now, the sandbox's codes (`AgentPageChats.wireSandbox`):
    /// Cloud off by policy, not signed in, or the Cloud app server's link, whose machines serve one
    /// connection (the app's own) and so take no folder copy (``CloudMove``'s `linkUnsupported`):
    /// refused before any machine is created for it. Not behind Labs (Leo, 2026-10-30: "that seems
    /// dumb. i dont like putting so much stuff in labs"): the person picked Cloud for this send.
    static func refusal(_ services: AppServices) -> String? {
        refusal(cloudDisabled: services.registry.disabledFeatures.contains(.cloud) || !services.cloud.mayCallCloud,
                signedIn: services.cloud.isSignedIn, appServerLink: services.cloud.configuration.linkSource == .appServer)
    }

    nonisolated static func refusal(cloudDisabled: Bool, signedIn: Bool, appServerLink: Bool = false) -> String? {
        if cloudDisabled { return "cloud_disabled" }
        guard signedIn else { return "not_signed_in" }
        return appServerLink ? "unavailable" : nil
    }

    /// Whether `path` is an existing folder, read off the main thread.
    @concurrent nonisolated private static func isFolder(_ path: String) async -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.checked.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The start; returns the machine's name.
    private func run(_ start: AgentPaneCloudStart, tab: TabModel, report: @MainActor (AgentPaneCloudStart.Step) -> Void) async throws -> String {
        guard !start.home else { return try await runHome(start, tab: tab, report: report) }
        // The folder the page named, as Move to Cloud's `path` takes one: an existing folder, never
        // the home folder or the disk's root. A page could already start a chat on this Mac in it.
        guard let chat = start.cwd ?? tab.cwd, await Self.isFolder(chat),
              let folder = CloudMoveFolder(chat: chat) else { throw CloudMove.Failure(message: CloudMoveStrings.noFolder) }
        guard !folder.isTooBroad else { throw CloudMove.Failure(message: CloudMoveStrings.homeFolder) }
        // A folder the page named is copied only as the pane checked it: its upload root, in the
        // pane's roots (``AgentPaneHandOff``). A `.git` found above it since then is refused.
        guard start.uploads(folder) else { throw CloudMove.Failure(message: CloudMoveStrings.noFolder) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .user)
        let folderName = URL(fileURLWithPath: chat).lastPathComponent
        report(.init(name: "machine", folder: folderName))
        // The machine, the pin and the keys are cmux-tui's (`cmux link start-chat`, +Machine).
        let account = services.cloud.account
        let (machine, plan) = try await self.machine(for: start, account: account, cli: cli, invocation: invocation) {
            await CloudChatPick(services: services).read(folder: chat, tab: tab)
        }
        let name = machine.machine.title, again = CloudMoveRetries.Retry.move(machineID: machine.machineID)
        // The account may have changed while the machine connected: copy nothing then.
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        // The chat's harness login (DEV and dogfood builds, +Login): it runs alongside the copy and is
        // awaited before the chat opens, so its first prompt starts signed in. It never fails the start.
        async let loginPassed = passHarnessLogin(start, machine: machine)
        let size = AgentPaneCloudStart.sizeText(machine.machine.size)
        report(.init(name: "folder", folder: folderName, machine: name, size: size))
        // Each copy goes to a new folder of the send's own, under its account as its pin; a retry whose
        // copy finished opens its chat without copying again, which would overwrite what it changed.
        let copy: (CloudMoveCLI.Answer, (chat: String, copied: Bool))
        do {
            // A machine whose older cmux-tui refuses the copy is updated to this app's build, then copied again on its new link (CloudOutdatedMachine).
            copy = try await CloudOutdatedMachine.copy(socket: { await machine.daemon.connection?.endpoint?.socketPath },
                                                       link: { CloudMachineUpdates.handshake(machine, machines: services.machines) },
                                                       notConnected: CloudMove.Failure(message: CloudMoveStrings.notConnected(name))) { socket in
                try await cli.startChatCopy(key: start.key, account: Self.accountText(account), machine: machine.machineID, socket: socket,
                                            local: folder.root, subpath: folder.subpath, workRoots: services.cloud.move.workRoots)
            } answer: { ($0.0.ok, $0.0.errorCode, $0.0.side) } update: { await CloudMachineUpdates.updateNow(machine.machineID, services: services) }
        } catch {
            // Timed out or didn't launch: Retry copies again on this machine, into a new folder.
            throw CloudMove.Failure(message: CloudMoveStrings.syncFailed(name, CloudStrings.errorText(error)), retry: again)
        }
        report(.init(name: "folder", folder: folderName, machine: name, size: size,
                     cloneState: copy.0.seedState, clonePhase: copy.0.seedPhase,
                     cloneStartedAt: copy.0.seedStartedAt, cloneFinishedAt: copy.0.seedFinishedAt))
        guard copy.0.ok else { throw CloudMove.failure(syncing: copy.0, machine: name, retry: again) }
        let remoteChat = copy.1.chat
        // The copy may take long: a chat whose account changed meanwhile opens nowhere, and this
        // Mac's tab stays.
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        _ = await loginPassed
        // The login may have waited on a confirm and a sign-in: check the account again after it.
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        report(.init(name: "opening", folder: folderName, machine: name, size: size))
        return try await open(start, tab: tab, on: machine, cwd: remoteChat, tabKey: plan.tabKey)
    }

    /// Opens the chat on `machine` in `cwd` under the plan's `tabKey` (a retry gets the same tab) and closes
    /// this Mac's tab: the chat is the machine's now.
    private func open(_ start: AgentPaneCloudStart, tab: TabModel, on machine: CloudMachineSession, cwd: String?,
                      tabKey: String) async throws -> String {
        let context = AppActionContext(services: services)
        let anchor = try await CloudHandlers.terminalAnchor(on: machine, context)
        let pending = try services.agentTabs.open(in: anchor.pane.handle, of: machine.daemon, seed: AgentPaneSeedSource(start.seed(cwd: cwd)),
                                                 idempotencyKey: tabKey)
        let opened = try await pending.value()
        CloudHandlers.show(anchor.id, context)
        if let pane = await machine.daemon.store.firstPane(mirroring: anchor.key) {
            for window in services.windows.controllers { window.state.selection.select(opened.key, in: pane.id) }
        }
        do {
            try await services.daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
        } catch {
            services.cloud.logger.error("cloud start chat: closing this Mac's tab failed: \(String(describing: error), privacy: .public)")
        }
        return machine.machine.title
    }

    /// A chat with no project: nothing is read or copied; the account is checked again as above.
    private func runHome(_ start: AgentPaneCloudStart, tab: TabModel, report: @MainActor (AgentPaneCloudStart.Step) -> Void) async throws -> String {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .user), account = services.cloud.account
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        report(.init(name: "machine"))
        let (machine, plan) = try await self.machine(for: start, account: account, cli: CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout),
                                                     invocation: invocation) { await CloudChatPick(services: services).read(folder: nil, tab: tab) }
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        // The harness login before the first prompt, as for a chat with a project (+Login).
        _ = await passHarnessLogin(start, machine: machine)
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        report(.init(name: "opening", machine: machine.machine.title, size: AgentPaneCloudStart.sizeText(machine.machine.size)))
        return try await open(start, tab: tab, on: machine, cwd: nil, tabKey: plan.tabKey)
    }
}
