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
/// Behind Labs preview features, like the picker's Cloud row.
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
                if let view { start.progress(step.name, folder: step.folder, machine: step.machine, size: step.size, to: view) }
            }
        }
    }

    /// The page's reply: success with the machine's name, or a refusal in the person's words.
    /// `report` tells the page's card each step as it begins (``AgentPaneCloudStart/progress(_:folder:machine:size:to:)``).
    func reply(_ start: AgentPaneCloudStart, tab: TabModel, report: @MainActor (Step) -> Void = { _ in }) async -> [String: Any] {
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

    /// Why no Cloud chat can start at all now, the sandbox's codes (`AgentPageChats.wireSandbox`).
    static func refusal(_ services: AppServices) -> String? {
        if services.registry.disabledFeatures.contains(.cloud) || !services.cloud.mayCallCloud { return "cloud_disabled" }
        if services.settings?.snapshot.previewFeatures != true { return "labs_off" }
        return services.cloud.isSignedIn ? nil : "not_signed_in"
    }

    /// Whether `folder` is what the send may copy: for a folder the page named, exactly the upload
    /// root the pane checked against its roots; the tab's own folder (no `cwd`) as Move to Cloud copies it.
    nonisolated static func uploads(_ folder: CloudMoveFolder, as start: AgentPaneCloudStart) -> Bool {
        guard start.cwd != nil else { return true }
        return start.uploadRoot == folder.root
    }

    /// Whether `path` is an existing folder, read off the main thread.
    @concurrent nonisolated private static func isFolder(_ path: String) async -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.checked.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The start; returns the machine's name.
    /// A step of the start as the page's card shows it.
    struct Step {
        var name: String
        var folder: String?
        var machine: String?
        var size: String?
    }

    /// A machine's size in the card's words: "4 CPU · 16 GB".
    static func sizeText(_ size: CloudMachine.Size?) -> String? {
        guard let cpu = size?.cpu, cpu > 0 else { return nil }
        guard let memory = size?.memoryMb, memory > 0 else { return "\(cpu) CPU" }
        return "\(cpu) CPU · \(Int((Double(memory) / 1024).rounded())) GB"
    }

    private func run(_ start: AgentPaneCloudStart, tab: TabModel, report: @MainActor (Step) -> Void) async throws -> String {
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
        let folderName = URL(fileURLWithPath: chat).lastPathComponent
        report(Step(name: "machine", folder: folderName))
        // This person's free machine (or one for chats), else a new one; a retry stays on its first try's (+Machine).
        let machine = try await self.machine(for: start, invocation: invocation) { await CloudChatPick(services: services).read(folder: chat, tab: tab) }
        let name = machine.machine.title, again = CloudMoveRetries.Retry.move(machineID: machine.machineID)
        guard let socket = await machine.daemon.connection?.endpoint?.socketPath else {
            throw CloudMove.Failure(message: CloudMoveStrings.notConnected(name))
        }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        let size = Self.sizeText(machine.machine.size)
        report(Step(name: "folder", folder: folderName, machine: name, size: size))
        // A retry whose copy finished opens its chat (by its tab key) without copying again: a
        // second push would overwrite what the chat already changed there.
        let destinations = services.cloud.startChatDestinations
        let remoteChat: String
        if let copied = destinations.copiedChat(for: start.key, on: machine.machineID) {
            remoteChat = copied
        } else {
            remoteChat = try await move.sync(folder, to: socket, machine: name, cli: cli, retry: again, place: start.remotePlace).chat
            destinations.recordCopy(remoteChat, for: start.key, on: machine.machineID)
        }
        let context = AppActionContext(services: services)
        let anchor = try await CloudHandlers.terminalAnchor(on: machine, context)
        report(Step(name: "opening", folder: folderName, machine: name, size: size))
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
