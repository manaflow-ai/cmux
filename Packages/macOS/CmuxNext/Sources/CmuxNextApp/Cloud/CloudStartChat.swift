import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// A new chat's first send with Cloud picked as where it runs (`cloud.startChat`,
/// ``AgentPaneCloudStart``; leo-workspace design/cloud-work-mode.md): the chat goes to Cloud with no
/// machine, size or environment prompt. It takes a free Cloud machine of this person's, else a new
/// one for chats sized for the chat by ``CloudChatPick`` (``machine(for:invocation:pick:)``), copies
/// the chat's folder there with Move to Cloud's sync, and opens a new chat on that machine in the
/// copied folder whose first prompt is the person's (a seeded prompt, sent once with the Send's
/// gesture, as onboarding's first task). This Mac's tab, which never started a chat, then closes.
///
/// Progress and failures are Move to Cloud's toasts, and the page gets the failure's message.
/// Not behind Labs: it needs Cloud allowed and a signed-in account (``refusal(_:)``).
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
            return await CloudStartChat(services: services).reply(start, tab: tab)
        }
    }

    /// The page's reply: success with the machine's name, or a refusal in the person's words.
    func reply(_ start: AgentPaneCloudStart, tab: TabModel) async -> [String: Any] {
        if let refusal = Self.refusal(services) { return AgentPaneReply.failure(code: refusal, message: refusal) }
        let toastID = "cloud-start-" + tab.id
        CloudMove.toast(services, toastID, CloudMoveStrings.moving, duration: .seconds(600))
        do {
            let machine = try await run(start, tab: tab)
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

    /// Whether `folder` is what the send may copy: for a folder the page named, exactly the upload
    /// root the pane checked against its roots; for the tab's own folder (no `cwd`), only that folder
    /// itself, never a Git working copy found above it, which no check covered (a tab in
    /// /repo/project never uploads /repo, its siblings and its history).
    /// The tab's own folder also never when it is the home folder or above it, by its canonical
    /// path too (a tab in /Users would copy every home folder's credentials).
    nonisolated static func uploads(_ folder: CloudMoveFolder, as start: AgentPaneCloudStart,
                                    home: String? = NSHomeDirectory()) -> Bool {
        guard start.cwd != nil else {
            guard folder.subpath.isEmpty else { return false }
            let canonicalHome = home.flatMap(AcpmuxPathPolicy.canonical) ?? home
            for path in [folder.root, AcpmuxPathPolicy.canonical(folder.root)].compactMap({ $0 })
            where AgentHome.isHomeOrAbove(path, home: canonicalHome) || AgentHome.isHomeOrAbove(path, home: home) {
                return false
            }
            return true
        }
        return start.uploadRoot == folder.root
    }

    /// Whether `path` is an existing folder, read off the main thread.
    @concurrent nonisolated private static func isFolder(_ path: String) async -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.checked.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The start; returns the machine's name.
    private func run(_ start: AgentPaneCloudStart, tab: TabModel) async throws -> String {
        // The folder the page named, as Move to Cloud's `path` takes one: an existing folder, never
        // the home folder or the disk's root. A page could already start a chat on this Mac in it.
        guard let chat = start.cwd ?? tab.cwd, await Self.isFolder(chat),
              let folder = CloudMoveFolder(chat: chat) else { throw CloudMove.Failure(message: CloudMoveStrings.noFolder) }
        guard !folder.isTooBroad else { throw CloudMove.Failure(message: CloudMoveStrings.homeFolder) }
        // A folder the page named is copied only as the pane checked it: its upload root, in the
        // pane's roots (``AgentPaneHandOff``). A `.git` found above it since then is refused.
        guard Self.uploads(folder, as: start) else { throw CloudMove.Failure(message: CloudMoveStrings.noFolder) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let move = CloudMove(services: services)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .user)
        // This person's free machine (or one for chats), else a new one; a retry stays on its first try's (+Machine).
        let account = services.cloud.account
        let machine = try await self.machine(for: start, account: account, invocation: invocation) { await CloudChatPick(services: services).read(folder: chat, tab: tab) }
        let name = machine.machine.title, again = CloudMoveRetries.Retry.move(machineID: machine.machineID)
        guard let socket = await machine.daemon.connection?.endpoint?.socketPath else {
            throw CloudMove.Failure(message: CloudMoveStrings.notConnected(name))
        }
        // The account may have changed while the machine connected: copy nothing then.
        try Self.checkAccount(account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        // A retry whose copy finished opens its chat (by its tab key) without copying again: a
        // second push would overwrite what the chat already changed there.
        let destinations = services.cloud.startChatDestinations
        let remoteChat: String
        if let copied = destinations.copiedChat(for: start.key, on: machine.machineID) {
            remoteChat = copied
        } else {
            let place = destinations.place(for: start.key, on: machine.machineID) { start.remotePlace + "/" + UUID().uuidString.prefix(8).lowercased() }
            remoteChat = try await move.sync(folder, to: socket, machine: name, cli: cli, retry: again, place: place).chat
            destinations.recordCopy(remoteChat, for: start.key, on: machine.machineID)
        }
        let context = AppActionContext(services: services)
        let anchor = try await CloudHandlers.terminalAnchor(on: machine, context)
        let seed = start.seed(cwd: remoteChat)
        let pending = try services.agentTabs.open(in: anchor.pane.handle, of: machine.daemon, seed: AgentPaneSeedSource(seed),
                                                 idempotencyKey: start.tabKey)
        let opened = try await pending.value()
        CloudHandlers.show(anchor.id, context)
        if let pane = await machine.daemon.store.firstPane(mirroring: anchor.key) {
            for window in services.windows.controllers { window.state.selection.select(opened.key, in: pane.id) }
        }
        // This Mac's tab never started a chat: the chat is the machine's now.
        do {
            try await services.daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
        } catch {
            services.cloud.logger.error("cloud start chat: closing this Mac's tab failed: \(String(describing: error), privacy: .public)")
        }
        return name
    }
}
