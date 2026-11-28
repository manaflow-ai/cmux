import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

/// Where a New Task runs: an agent chat, or the agent's own CLI in a terminal (classic's tasks).
public enum TaskLaunch: String, Hashable, Sendable, Codable, CaseIterable {
    case chat, terminal

    public var title: String {
        switch self {
        case .chat: "Chat"
        case .terminal: "Terminal"
        }
    }

    public var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .terminal: "apple.terminal"
        }
    }
}

/// New Task's first message to an agent: the prompt, the photos and files that go with it, the
/// model, and where it runs.
public struct AgentTask: Hashable, Sendable {
    public var prompt: String
    public var images: [TaskImage]
    public var files: [TaskFile]
    /// The model id, or nil for the agent's default (the Mac's last pick for it).
    public var model: String?
    public var launch: TaskLaunch
    /// The agent's family (`claude`, `codex`): its CLI, for a terminal launch.
    public var family: String?
    /// The effort level, or nil for the model's default.
    public var effort: String?
    /// The mode the chat starts in, or nil for the Mac's start mode.
    public var mode: String?
    /// The agent's other options, by option id.
    public var options: [String: String]

    public init(prompt: String, images: [TaskImage] = [], files: [TaskFile] = [], model: String? = nil,
                launch: TaskLaunch = .chat, family: String? = nil, effort: String? = nil, mode: String? = nil,
                options: [String: String] = [:]) {
        self.prompt = prompt
        self.images = images
        self.files = files
        self.model = model
        self.launch = launch
        self.family = family
        self.effort = effort
        self.mode = mode
        self.options = options
    }

    /// The command a terminal launch types into the new workspace's shell (zsh or bash, the
    /// Mac's default shells): `cd` to the folder and, only if that worked, the agent's CLI with its
    /// model and the prompt, the uploaded attachments' paths after it. Nil for an agent with no
    /// known CLI. The quoting and flag rules are Rust's `task_terminal_line`
    /// (cmux-mobile-link-ffi `task_composer.rs`): every value one ANSI-C quoted word, so nothing
    /// in it runs. Nil off iOS too, where the Rust library is not linked (only tests build there).
    public func terminalLine(folder: String? = nil, attachmentPaths: [String] = []) -> String? {
        #if os(iOS)
        taskTerminalLine(launch: TaskTerminalLaunch(prompt: prompt, model: model, family: family, effort: effort, mode: mode,
                                                    folder: folder, attachmentPaths: attachmentPaths))
        #else
        nil
        #endif
    }
}

/// A file attached in New Task (any kind): uploaded to the task's folder on the Mac and named
/// in the first message.
public struct TaskFile: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var data: Data

    public init(id: String = UUID().uuidString, name: String, data: Data) {
        self.id = id
        self.name = name
        self.data = data
    }
}

/// An image attached in New Task: JPEG, PNG, GIF or WebP bytes, sent as an ACP `image` block.
public struct TaskImage: Hashable, Sendable, Identifiable {
    public var id: String
    public var data: Data

    public init(id: String = UUID().uuidString, data: Data) {
        self.id = id
        self.data = data
    }

    #if os(iOS)
    /// The MIME type from the bytes' signature (Rust's `task_image_mime_type`); nil for a format
    /// agents don't take.
    public var mimeType: String? { taskImageMimeType(head: Data(data.prefix(12))) }
    #endif
}

/// A Cloud machine New Task can run on, as a connected Mac lists it (Cloud chats reach the phone
/// through that Mac). The Cloud machine starts Claude, asking before it acts, in a folder it makes.
public struct CloudTaskTarget: Hashable, Sendable, Identifiable {
    public var teamID: String
    public var machineID: String
    public var name: String
    /// The Mac that lists it and carries its chat.
    public var macID: String
    public var id: String { teamID + "\u{1}" + machineID }

    public init(teamID: String, machineID: String, name: String, macID: String) {
        self.teamID = teamID
        self.machineID = machineID
        self.name = name
        self.macID = macID
    }
}

/// One agent New Task starts: a harness of the Mac's catalog and its model (nil: its default).
public struct TaskAgentPick: Hashable, Sendable, Identifiable, Codable {
    public var harness: String
    public var model: String?
    /// The agent's name as the Mac lists it ("Claude Code Router"), for the workspace title.
    public var name: String?
    /// The agent's family (`claude`, `codex`): its CLI when the task opens in a terminal.
    public var family: String?
    /// The effort level, or nil for the model's own default (as the Mac lists them).
    public var effort: String?
    /// The mode the chat starts in (one the Mac lets a phone start), or nil for the first.
    public var mode: String?
    /// The agent's other options (`fast-mode: on`), by option id; nil or empty: its defaults.
    public var options: [String: String]?
    public var id: String { harness }

    public init(harness: String, model: String? = nil, name: String? = nil, family: String? = nil, effort: String? = nil,
                mode: String? = nil, options: [String: String]? = nil) {
        self.harness = harness
        self.model = model
        self.name = name
        self.family = family
        self.effort = effort
        self.mode = mode
        self.options = options
    }
}

/// New Task's composer: what to do, which agents do it (one workspace each), where, and the
/// workspace's name. Kept by `WorkspaceCreator.taskDraft` while the sheet is closed.
public struct TaskDraft: Hashable, Sendable {
    /// The draft's identity in the drafts list: every save of this composer session updates it.
    public var id: UUID
    public var prompt: String
    public var images: [TaskImage]
    public var files: [TaskFile]
    /// The chosen agents, in the order they were chosen. Empty: the Mac's default agent.
    public var picks: [TaskAgentPick]
    /// The Mac, or nil for the creator's target Mac.
    public var macID: String?
    /// A Cloud machine (``CloudTaskTarget/id``) the task runs on instead of a Mac; nil: a Mac.
    public var cloudID: String?
    /// One of the Mac's workspace folders, or nil for the most recent one.
    public var directory: String?
    /// The workspace name; empty names it after the prompt.
    public var name: String
    /// Where the task runs: an agent chat or the agent's CLI in a terminal.
    public var launch: TaskLaunch

    public init(id: UUID = UUID(), prompt: String = "", images: [TaskImage] = [], files: [TaskFile] = [],
                picks: [TaskAgentPick] = [], macID: String? = nil, cloudID: String? = nil, directory: String? = nil,
                name: String = "", launch: TaskLaunch = .terminal) {
        self.id = id
        self.prompt = prompt
        self.images = images
        self.files = files
        self.picks = picks
        self.macID = macID
        self.cloudID = cloudID
        self.directory = directory
        self.name = name
        self.launch = launch
    }

    /// The prompt as sent: surrounding blank lines and spaces removed.
    public var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nothing typed, attached or named: Cancel loses nothing worth keeping.
    public var isEmpty: Bool {
        trimmedPrompt.isEmpty && images.isEmpty && files.isEmpty && name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The most images one task sends (each goes inline in the first message).
    public static let imageLimit = 6
    /// The most files one task attaches, and the most bytes each may have (held in memory).
    public static let fileLimit = 6
    public static let maxFileBytes = 25 << 20
    /// The most agents one task starts at once (one workspace each).
    public static let agentLimit = 4
    /// A title from the prompt is cut to this many characters.
    static let titleLength = 48

    /// What a tap on an agent's row did (``toggle(_:fallback:)``).
    public enum PickChange: Equatable, Sendable {
        case added, removed
        /// The last agent stays: a task always has one.
        case keptLast
        /// ``agentLimit`` agents are chosen already.
        case atLimit
        /// A phone can't start this agent.
        case unavailable
    }

    #if os(iOS)
    /// A tap on `harness`'s row: picks it, or unpicks it unless it is the last. With no pick,
    /// the agent the task would start (`fallback`, shown checked) becomes a real pick first.
    /// The rules are Rust's `task_pick_toggle`; a kept agent keeps its settings.
    @discardableResult
    public mutating func toggle(_ harness: AgentHarnessChoice, fallback: AgentHarnessChoice?) -> PickChange {
        let result = taskPickToggle(picks: picks.map(\.harness), harness: harness.id, canStart: harness.canStart,
                                    fallback: fallback?.id, limit: UInt32(Self.agentLimit))
        let kept = Dictionary(picks.map { ($0.harness, $0) }, uniquingKeysWith: { first, _ in first })
        picks = result.picks.map { id in
            if let pick = kept[id] { return pick }
            let choice = id == harness.id ? harness : fallback
            return TaskAgentPick(harness: id, name: choice?.name, family: choice?.family)
        }
        switch result.change {
        case .added: return .added
        case .removed: return .removed
        case .keptLast: return .keptLast
        case .atLimit: return .atLimit
        case .unavailable: return .unavailable
        }
    }
    #endif

    /// Another Mac: its agents are its own, so the picks go (the folder is checked against its list).
    public mutating func chooseMac(_ macID: String) {
        cloudID = nil
        guard macID != self.macID else { return }
        self.macID = macID
        picks = []
    }

    /// A Cloud machine instead of a Mac: the Mac's picks and folder stay for when a Mac is chosen
    /// again (the Cloud machine starts Claude in a folder it makes).
    public mutating func chooseCloud(_ cloudID: String) {
        self.cloudID = cloudID
    }

    /// The workspace title: the typed name, else the prompt's first line, shortened at a word.
    public var title: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let line = trimmedPrompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "New Task" }
        guard line.count > Self.titleLength else { return line }
        let cut = line.prefix(Self.titleLength)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Why a task workspace's first message didn't get to its agent, by what the phone knows.
public enum TaskDeliveryFailure: Hashable, Sendable {
    /// Nothing left the phone: the task can go again from the chat's composer.
    case notSent(String)
    /// The link dropped after it left: the agent may have it.
    case uncertain(String)
    /// The Mac's agent refused it.
    case refused(String)

    public var reason: String {
        switch self {
        case .notSent(let reason), .uncertain(let reason), .refused(let reason): reason
        }
    }
}

/// Why New Task's Start is off, in the composer's words; nil when it can start.
public enum TaskStartBlocker: Hashable, Sendable {
    case noMac
    case noPrompt
    case noAgent
    case noFolder
    case tooManyAgents
    /// The chosen Cloud machine isn't listed by any connected Mac now.
    case noCloud
    /// A Cloud task's first message is text: photos and files go only to a Mac's folder.
    case cloudTextOnly

    public var message: String {
        switch self {
        case .noMac: "No Mac is online to start the task on."
        case .noPrompt: "Describe the task to start it."
        case .noAgent: "Choose an agent to run the task."
        case .noFolder: "Agents start in a project folder that's open on the Mac. Open a workspace there first (New Workspace › Open Folder…)."
        case .tooManyAgents: "Choose at most \(TaskDraft.agentLimit) agents."
        case .noCloud: "This Cloud machine isn't reachable now. Wake it on your Mac, or choose another place to run the task."
        case .cloudTextOnly: "A Cloud task starts with text only. Remove the photos and files, or run the task on a Mac."
        }
    }
}

extension WorkspaceCreator {
    /// Whether `macID` can start agent tasks from this phone now (its agents are connected).
    public func canStartTasks(on macID: String) -> Bool {
        availableMacs.contains { $0.id == macID } && !options(on: macID).agents.isEmpty
    }

    /// The Macs New Task can start on, in team order.
    public var taskMacs: [MacDevice] { availableMacs.filter { !options(on: $0.id).agents.isEmpty } }

    /// The Mac a draft starts on: its own when still available, else the target Mac when it
    /// takes tasks, else the first that does.
    public func taskMac(for draft: TaskDraft) -> MacDevice? {
        let macs = taskMacs
        return macs.first { $0.id == draft.macID } ?? macs.first { $0.id == targetMac?.id } ?? macs.first
    }

    /// The Cloud machine a draft runs on; nil for a Mac (or a Cloud machine no Mac lists now).
    public func taskCloud(for draft: TaskDraft) -> CloudTaskTarget? {
        draft.cloudID.flatMap { id in cloudTaskTargets.first { $0.id == id } }
    }

    /// Reads the Cloud machines New Task can run on (through the connected Macs). A failed read
    /// keeps the last list, so a chosen machine stays chosen through a blip.
    public func refreshCloudTaskTargets() async {
        guard let loadCloudTaskTargets else { return }
        guard let listed = await loadCloudTaskTargets() else { return }
        cloudTaskTargets = listed
    }

    /// Starts a Cloud task: the shell opens the machine's new Claude chat with the prompt as its
    /// first message. Clears the draft (the Cloud machine stays chosen). False when it can't start.
    @discardableResult
    public func startCloudTask(_ draft: TaskDraft) -> Bool {
        guard taskBlocker(draft) == nil, let target = taskCloud(for: draft), let openCloudTask else { return false }
        openCloudTask(target, draft.trimmedPrompt)
        taskDrafts.delete([draft.id])
        taskDraft = TaskDraft(picks: draft.picks, macID: draft.macID, cloudID: target.id, directory: draft.directory,
                              launch: draft.launch)
        rememberTaskSetup()
        taskRefusal = nil
        restoredTask = nil
        return true
    }

    /// The folders a task may start in on `macID`: the Mac's workspace folders, never home.
    public func taskFolders(on macID: String) -> [String] {
        recentDirectories(on: macID).filter { $0 != "~" && $0 != "/" && !$0.isEmpty }
    }

    /// The folder a draft starts in on `macID`: its own when listed, else the most recent.
    public func taskFolder(for draft: TaskDraft, on macID: String) -> String? {
        let folders = taskFolders(on: macID)
        return draft.directory.flatMap { folders.contains($0) ? $0 : nil } ?? folders.first
    }

    /// The Mac's agents and models for New Task.
    public func agentCatalog(on macID: String) async throws -> AgentCatalog {
        try await backend.agentCatalog(on: macID)
    }

    /// Why `draft` can't start now; nil when it can.
    public func taskBlocker(_ draft: TaskDraft) -> TaskStartBlocker? {
        if draft.cloudID != nil {
            guard taskCloud(for: draft) != nil else { return .noCloud }
            if draft.trimmedPrompt.isEmpty { return .noPrompt }
            if !draft.images.isEmpty || !draft.files.isEmpty { return .cloudTextOnly }
            return nil
        }
        guard let mac = taskMac(for: draft) else { return .noMac }
        if draft.trimmedPrompt.isEmpty { return .noPrompt }
        if draft.picks.count > TaskDraft.agentLimit { return .tooManyAgents }
        if taskFolder(for: draft, on: mac.id) == nil { return .noFolder }
        return nil
    }

    /// Starts the task: one workspace per chosen agent (the Mac's default agent when none is
    /// chosen), each an optimistic row at once, whose chat gets the prompt and images as its
    /// first message. Clears the draft. Returns the placeholders (empty when it can't start).
    @discardableResult
    public func startTask(_ draft: TaskDraft) -> [Workspace] {
        guard taskBlocker(draft) == nil, let mac = taskMac(for: draft), let folder = taskFolder(for: draft, on: mac.id) else {
            return []
        }
        let picks = draft.picks.isEmpty ? [TaskAgentPick(harness: "")] : draft.picks
        var titles = store.workspaces.filter { $0.macID == mac.id }.map(\.title)
        var made: [Workspace] = []
        for pick in picks {
            // A chat: the agent's chat tab, the task its first message. A terminal: a terminal tab
            // whose shell runs the agent's CLI with the task.
            let start: NewWorkspaceStart = draft.launch == .terminal ? .terminal : .agent(pick.harness)
            let request = NewWorkspaceRequest(macID: mac.id, directory: folder, start: start,
                                              task: AgentTask(prompt: draft.trimmedPrompt, images: draft.images, files: draft.files,
                                                              model: pick.model, launch: draft.launch, family: pick.family,
                                                              effort: pick.effort, mode: pick.mode, options: pick.options ?? [:]))
            // The agent first: a long task title truncates, and rows of one task differ only by agent.
            let base = picks.count > 1 ? "\(pick.name ?? Self.agentTitle(pick.harness)) · \(draft.title)" : draft.title
            let placeholder = Self.taskPlaceholder(for: request, title: Self.uniqueTitle(base, existing: titles), task: draft.title)
            titles.append(placeholder.title)
            var origin = draft
            // A pick of "" (the Mac's default agent) comes back as no pick.
            origin.picks = pick.harness.isEmpty ? [] : [pick]
            taskOrigins[placeholder.id] = origin
            begin(request, placeholder: placeholder, focus: picks.count == 1)
            made.append(placeholder)
        }
        // Sent: it leaves the drafts list. Not kept on disk while its workspaces are made: after
        // an app kill, a kept copy could not tell which agents already have the task, and one
        // Start would run it twice (review 2026-11-14). A refusal saves it again at once.
        taskDrafts.delete([draft.id])
        rememberAgentSettings(picks)
        taskDraft = TaskDraft(picks: draft.picks, macID: mac.id, directory: folder, launch: draft.launch)
        rememberTaskSetup()
        taskRefusal = nil
        restoredTask = nil
        return made
    }

    /// Sends a created task workspace its task (the backend sends it on its own task).
    func deliver(_ task: AgentTask, to workspace: Workspace) {
        let report: @MainActor (TaskDeliveryFailure) -> Void = { [weak self] failure in
            guard let self else { return }
            onTaskNotDelivered?(store.workspace(id: workspace.id) ?? workspace, task, failure)
        }
        do {
            try backend.sendTask(task, in: workspace, failed: report)
        } catch {
            report(.notSent(Self.message(error)))
        }
    }

    /// A refused task workspace gives its task back: in the composer when it is empty (or
    /// holds the same task, refused by another of its agents), else in the drafts list, so it
    /// is never lost. `reason`: the Mac's refusal, shown in New Task.
    func restoreTaskDraft(after placeholderID: String, reason: String?) {
        guard let origin = taskOrigins.removeValue(forKey: placeholderID) else { return }
        var task = origin
        task.picks = []
        let why = reason?.isEmpty == false ? reason
            : "The Mac couldn't start this task. Check that cmux is running on it, then start it again."
        if taskDraft.id == origin.id {
            // The composer holds this task, given back for another of its agents (and maybe
            // edited since): this agent joins it; the person's edits stay.
            taskDraft.picks += origin.picks.filter { !taskDraft.picks.contains($0) }
            refusedTasks[placeholderID] = .composer
            taskRefusal = why
            saveTaskDraft()
        } else if taskDraft.isEmpty {
            // Only this agent comes back: the task's other agents may have started it already.
            // Saved at once too: the app may be gone before the composer opens again.
            taskDraft = origin
            restoredTask = task
            refusedTasks[placeholderID] = .composer
            taskRefusal = why
            saveTaskDraft()
        } else if taskDrafts.entry(origin.id) != nil {
            // Saved to the drafts list for another of its agents (maybe edited since): only
            // this agent joins it, nothing else of the saved draft changes.
            taskDrafts.addPicks(origin.picks, to: origin.id)
            refusedTasks[placeholderID] = .drafts
        } else {
            taskDrafts.save(origin)
            refusedTasks[placeholderID] = .drafts
        }
    }

    /// Whether `placeholderID` was a New Task workspace the Mac refused (its task is back in the
    /// composer or in the drafts list).
    public func wasRefusedTask(_ placeholderID: String) -> Bool {
        guard let place = refusedTasks[placeholderID] else { return false }
        return place != .mayHaveStarted
    }

    /// Where a refused New Task went: back in the composer, or into the drafts list.
    public enum RefusedTaskPlace: Hashable, Sendable {
        case composer, drafts
        /// Not handed back: the agent's command may already run in a terminal on the Mac.
        case mayHaveStarted
    }

    /// Where `placeholderID`'s refused task went; nil when it was not a refused New Task.
    public func refusedTaskPlace(_ placeholderID: String) -> RefusedTaskPlace? { refusedTasks[placeholderID] }

    // MARK: Drafts

    /// The draft the composer holds, saved to the drafts list (an empty one is not kept). Its
    /// Mac and folder are kept as they are now (the most recent folder would change by the
    /// time it is resumed).
    public func saveTaskDraft() {
        var draft = taskDraft
        if let mac = taskMac(for: draft) {
            draft.macID = draft.macID ?? mac.id
            draft.directory = draft.directory ?? taskFolder(for: draft, on: mac.id)
        }
        taskDrafts.save(draft)
    }

    /// Whether leaving the composer now would lose something: it holds a task that the drafts
    /// list doesn't have as it is (a resumed draft left as it was asks nothing).
    public var taskDraftNeedsSaving: Bool {
        guard !taskDraft.isEmpty else { return false }
        guard let saved = taskDrafts.entry(taskDraft.id) else { return true }
        var draft = taskDraft
        // Compared as it would be saved (its Mac and folder filled in).
        if let mac = taskMac(for: draft) {
            draft.macID = draft.macID ?? mac.id
            draft.directory = draft.directory ?? taskFolder(for: draft, on: mac.id)
        }
        return !saved.sameContent(as: SavedTaskDraft(draft, updatedAt: saved.updatedAt))
    }

    /// Leaves the composer: `keep` saves its draft to the drafts list, else deletes it there.
    /// The composer's next task starts empty, with the same agents and place.
    public func leaveTaskComposer(keep: Bool) {
        if keep { saveTaskDraft() } else { taskDrafts.delete([taskDraft.id]) }
        taskDraft = TaskDraft(picks: taskDraft.picks, macID: taskDraft.macID, cloudID: taskDraft.cloudID,
                              directory: taskDraft.directory, launch: taskDraft.launch)
        rememberTaskSetup()
        taskRefusal = nil
        restoredTask = nil
    }

    /// New Draft: the one held is saved, and an empty one with the same agents and place starts.
    public func newTaskDraft() {
        leaveTaskComposer(keep: true)
    }

    /// Opens a saved draft in the composer, after saving the one it held. False when the draft
    /// is gone (deleted meanwhile).
    @discardableResult
    public func resumeTaskDraft(_ id: UUID) async -> Bool {
        guard id != taskDraft.id else { return true }
        guard let draft = await taskDrafts.draft(id) else { return false }
        saveTaskDraft()
        taskDraft = draft
        taskRefusal = nil
        restoredTask = nil
        return true
    }

    static let taskLaunchKey = "cmuxMobile.newTask.launch"
    static let taskSetupKey = "cmuxMobile.newTask.setup"

    /// The composer's setup as it is now: its agents, Mac, folder and Chat or Terminal (each
    /// agent's model, effort, mode and options are kept per agent, `rememberAgentSettings`).
    struct TaskSetup: Codable {
        var picks: [TaskAgentPick]
        var macID: String?
        /// The Cloud machine New Task runs on (nil: a Mac); absent in setups kept before Cloud.
        var cloudID: String?
        var directory: String?
    }

    /// Keeps the composer's setup for the next task, also after the app quits: the next task
    /// starts with the same agents, Mac, folder and Chat or Terminal.
    func rememberTaskSetup() {
        rememberTaskLaunch(taskDraft.launch)
        let setup = TaskSetup(picks: taskDraft.picks.map { TaskAgentPick(harness: $0.harness, name: $0.name, family: $0.family) },
                              macID: taskDraft.macID, cloudID: taskDraft.cloudID, directory: taskDraft.directory)
        defaults.set(try? JSONEncoder().encode(setup), forKey: Self.taskSetupKey)
    }

    /// The last setup (`rememberTaskSetup`), into an empty composer at launch.
    func restoreTaskSetup() {
        if let raw = defaults.string(forKey: Self.taskLaunchKey), let launch = TaskLaunch(rawValue: raw) { taskDraft.launch = launch }
        guard let data = defaults.data(forKey: Self.taskSetupKey),
              let setup = try? JSONDecoder().decode(TaskSetup.self, from: data) else { return }
        taskDraft.picks = setup.picks
        taskDraft.macID = setup.macID
        taskDraft.cloudID = setup.cloudID
        taskDraft.directory = setup.directory
    }

    /// Keeps where New Task opens for the next launch of the app.
    func rememberTaskLaunch(_ launch: TaskLaunch) {
        defaults.set(launch.rawValue, forKey: Self.taskLaunchKey)
    }

    static let agentSettingsKey = "cmuxMobile.newTask.agentSettings"

    /// Keeps each started agent's model, effort, mode and options: the next task's pickers start
    /// on them (the person's last picks), by agent.
    func rememberAgentSettings(_ picks: [TaskAgentPick]) {
        var kept = (defaults.dictionary(forKey: Self.agentSettingsKey) as? [String: Data]) ?? [:]
        for pick in picks where !pick.harness.isEmpty {
            let settings = TaskAgentPick(harness: pick.harness, model: pick.model, effort: pick.effort, mode: pick.mode,
                                         options: pick.options)
            kept[pick.harness] = try? JSONEncoder().encode(settings)
        }
        defaults.set(kept, forKey: Self.agentSettingsKey)
    }

    /// `harness`'s last started model, effort, mode and options on this phone, or nil.
    public func lastAgentSettings(_ harness: String) -> TaskAgentPick? {
        guard let data = (defaults.dictionary(forKey: Self.agentSettingsKey) as? [String: Data])?[harness] else { return nil }
        return try? JSONDecoder().decode(TaskAgentPick.self, from: data)
    }

    /// `pick` with every setting it leaves open filled in: the person's last pick for its agent
    /// when the Mac still offers it, else the Mac's own default. What the pickers show, and what
    /// Start sends, so the Mac runs what the phone showed.
    public func settled(_ pick: TaskAgentPick, harness: AgentHarnessChoice, catalog: AgentCatalog) -> TaskAgentPick {
        var pick = pick
        let last = lastAgentSettings(harness.id)
        // A model this agent no longer lists (a draft kept from an older catalog) is not kept
        // invisibly: its picker would read Default while Start sent it. It falls back as no pick.
        if let model = pick.model, harness.model(model) == nil, !harness.models.isEmpty || model != harness.defaultModel {
            pick.model = nil
        }
        if pick.model == nil {
            let remembered = last?.model.flatMap { id in harness.model(id).flatMap { $0.unavailableReason == nil ? $0.id : nil } }
            let start = catalog.resolve(AgentChatStart(harness: harness.id))?.model
            // A release by its id: an alias the Mac picked last (`opus`) names its release.
            pick.model = remembered ?? harness.model(start)?.id ?? start ?? harness.offeredDefaultModel
        } else if let release = harness.model(pick.model)?.id {
            pick.model = release
        }
        let efforts = harness.efforts(model: pick.model)
        if pick.effort.map({ id in !efforts.contains { $0.id == id } }) ?? true {
            pick.effort = last?.effort.flatMap { id in efforts.contains { $0.id == id } ? id : nil } ?? harness.defaultEffort(model: pick.model)
        }
        if pick.mode.map({ !harness.askingModes.contains($0) }) ?? true {
            pick.mode = last?.mode.flatMap { harness.askingModes.contains($0) ? $0 : nil } ?? harness.askingModes.first
        }
        var options: [String: String] = [:]
        for option in harness.configOptions {
            let offered = { (value: String?) in value.flatMap { v in option.choices.contains { $0.id == v } ? v : nil } }
            if let value = offered(pick.options?[option.id]) ?? offered(last?.options?[option.id]) { options[option.id] = value }
        }
        pick.options = options.isEmpty ? nil : options
        return pick
    }

    /// The drafts list's rows: the saved drafts but the one the composer holds.
    public var otherTaskDrafts: [SavedTaskDraft] { taskDrafts.drafts.filter { $0.id != taskDraft.id } }

    /// "Claude", "Codex", else the harness capitalized; "Agent" for the Mac's default.
    public static func agentTitle(_ harness: String) -> String {
        switch harness {
        case "": "Agent"
        case "claude": "Claude"
        case "codex": "Codex"
        default: harness.prefix(1).uppercased() + harness.dropFirst()
        }
    }

    /// The optimistic task workspace: titled `title`, its one tab the agent working on `task` (a
    /// chat tab, or for a terminal launch a terminal tab named for the agent).
    static func taskPlaceholder(for request: NewWorkspaceRequest, title: String, task: String, now: Date = Date()) -> Workspace {
        var workspace = placeholder(for: request, existing: [], now: now)
        workspace.title = title
        // A terminal launch keeps the placeholder's terminal tab as the Mac will list it (named
        // for its shell and folder), so nothing flips when the Mac's tab replaces it.
        if case .agent(let harness) = request.start, !workspace.tabs.isEmpty {
            // The tab is the agent, as the Mac's tab for the chat reads once listed (its pill
            // then shows the agent's name, with no flip); the workspace's title is the task.
            workspace.tabs[0].title = agentTitle(harness)
            workspace.tabs[0].subtitle = nil
            workspace.tabs[0].agentStatus = .working
        }
        return workspace
    }
}
