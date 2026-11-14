import Foundation

/// New Task's first message to an agent: the prompt, the images that go with it, and the model.
public struct AgentTask: Hashable, Sendable {
    public var prompt: String
    public var images: [TaskImage]
    /// The model id, or nil for the agent's default (the Mac's last pick for it).
    public var model: String?

    public init(prompt: String, images: [TaskImage] = [], model: String? = nil) {
        self.prompt = prompt
        self.images = images
        self.model = model
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

    /// The MIME type from the bytes' signature; nil for a format agents don't take.
    public var mimeType: String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }
}

/// One agent New Task starts: a harness of the Mac's catalog and its model (nil: its default).
public struct TaskAgentPick: Hashable, Sendable, Identifiable, Codable {
    public var harness: String
    public var model: String?
    /// The agent's name as the Mac lists it ("Claude Code Router"), for the workspace title.
    public var name: String?
    public var id: String { harness }

    public init(harness: String, model: String? = nil, name: String? = nil) {
        self.harness = harness
        self.model = model
        self.name = name
    }
}

/// New Task's composer: what to do, which agents do it (one workspace each), where, and the
/// workspace's name. Kept by `WorkspaceCreator.taskDraft` while the sheet is closed.
public struct TaskDraft: Hashable, Sendable {
    /// The draft's identity in the drafts list: every save of this composer session updates it.
    public var id: UUID
    public var prompt: String
    public var images: [TaskImage]
    /// The chosen agents, in the order they were chosen. Empty: the Mac's default agent.
    public var picks: [TaskAgentPick]
    /// The Mac, or nil for the creator's target Mac.
    public var macID: String?
    /// One of the Mac's workspace folders, or nil for the most recent one.
    public var directory: String?
    /// The workspace name; empty names it after the prompt.
    public var name: String

    public init(id: UUID = UUID(), prompt: String = "", images: [TaskImage] = [], picks: [TaskAgentPick] = [],
                macID: String? = nil, directory: String? = nil, name: String = "") {
        self.id = id
        self.prompt = prompt
        self.images = images
        self.picks = picks
        self.macID = macID
        self.directory = directory
        self.name = name
    }

    /// The prompt as sent: surrounding blank lines and spaces removed.
    public var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nothing typed, attached or named: Cancel loses nothing worth keeping.
    public var isEmpty: Bool { trimmedPrompt.isEmpty && images.isEmpty && name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The most images one task sends (each goes inline in the first message).
    public static let imageLimit = 6
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

    /// A tap on `harness`'s row: picks it, or unpicks it unless it is the last. With no pick,
    /// the agent the task would start (`fallback`, shown checked) becomes a real pick first.
    @discardableResult
    public mutating func toggle(_ harness: AgentHarnessChoice, fallback: AgentHarnessChoice?) -> PickChange {
        guard harness.canStart else { return .unavailable }
        if picks.isEmpty, let fallback { picks = [TaskAgentPick(harness: fallback.id, name: fallback.name)] }
        if let index = picks.firstIndex(where: { $0.harness == harness.id }) {
            guard picks.count > 1 else { return .keptLast }
            picks.remove(at: index)
            return .removed
        }
        guard picks.count < Self.agentLimit else { return .atLimit }
        picks.append(TaskAgentPick(harness: harness.id, name: harness.name))
        return .added
    }

    /// Another Mac: its agents are its own, so the picks go (the folder is checked against its list).
    public mutating func chooseMac(_ macID: String) {
        guard macID != self.macID else { return }
        self.macID = macID
        picks = []
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

    public var message: String {
        switch self {
        case .noMac: "No Mac is online to start the task on."
        case .noPrompt: "Describe the task to start it."
        case .noAgent: "Choose an agent to run the task."
        case .noFolder: "Agents start in a project folder that's open on the Mac. Open a workspace there first (New Workspace › Open Folder…)."
        case .tooManyAgents: "Choose at most \(TaskDraft.agentLimit) agents."
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
            let request = NewWorkspaceRequest(macID: mac.id, directory: folder, start: .agent(pick.harness),
                                              task: AgentTask(prompt: draft.trimmedPrompt, images: draft.images, model: pick.model))
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
        // Sent: it leaves the drafts list. The next task starts with the same agents and place.
        taskDrafts.delete([draft.id])
        taskDraft = TaskDraft(picks: draft.picks, macID: draft.macID, directory: draft.directory)
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
        if taskDraft.isEmpty {
            // Only this agent comes back: the task's other agents may have started it already.
            taskDraft = origin
            restoredTask = task
            refusedTasks[placeholderID] = .composer
            taskRefusal = why
        } else if restoredTask == task, taskDraftMatches(origin) {
            // Another agent of the same task failed too: it joins the draft given back.
            taskDraft.picks += origin.picks.filter { !taskDraft.picks.contains($0) }
            refusedTasks[placeholderID] = .composer
            taskRefusal = why
        } else if let saved = taskDrafts.entry(origin.id), saved.prompt == origin.prompt {
            // Another agent of a task already saved to the drafts list: it joins that draft.
            var merged = origin
            merged.picks = saved.picks + origin.picks.filter { !saved.picks.contains($0) }
            taskDrafts.save(merged)
            refusedTasks[placeholderID] = .drafts
        } else {
            taskDrafts.save(origin)
            refusedTasks[placeholderID] = .drafts
        }
    }

    /// Whether the composer holds `origin`'s task (its prompt, photos, name and place).
    private func taskDraftMatches(_ origin: TaskDraft) -> Bool {
        taskDraft.prompt == origin.prompt && taskDraft.images == origin.images && taskDraft.name == origin.name
            && taskDraft.macID == origin.macID && taskDraft.directory == origin.directory
    }

    /// Whether `placeholderID` was a New Task workspace the Mac refused (its task is back in the
    /// composer or in the drafts list).
    public func wasRefusedTask(_ placeholderID: String) -> Bool { refusedTasks[placeholderID] != nil }

    /// Where a refused New Task went: back in the composer, or into the drafts list.
    public enum RefusedTaskPlace: Hashable, Sendable { case composer, drafts }

    /// Where `placeholderID`'s refused task went; nil when it was not a refused New Task.
    public func refusedTaskPlace(_ placeholderID: String) -> RefusedTaskPlace? { refusedTasks[placeholderID] }

    // MARK: Drafts

    /// The draft the composer holds, saved to the drafts list (an empty one is not kept).
    public func saveTaskDraft() {
        taskDrafts.save(taskDraft)
    }

    /// Whether leaving the composer now would lose something: it holds a task that the drafts
    /// list doesn't have as it is (a resumed draft left as it was asks nothing).
    public var taskDraftNeedsSaving: Bool {
        guard !taskDraft.isEmpty else { return false }
        guard let saved = taskDrafts.entry(taskDraft.id) else { return true }
        return !saved.sameContent(as: SavedTaskDraft(taskDraft, updatedAt: saved.updatedAt))
    }

    /// Leaves the composer: `keep` saves its draft to the drafts list, else deletes it there.
    /// The composer's next task starts empty, with the same agents and place.
    public func leaveTaskComposer(keep: Bool) {
        if keep { saveTaskDraft() } else { taskDrafts.delete([taskDraft.id]) }
        taskDraft = TaskDraft(picks: taskDraft.picks, macID: taskDraft.macID, directory: taskDraft.directory)
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

    /// The optimistic task workspace: titled `title`, its one tab the agent working on `task`.
    static func taskPlaceholder(for request: NewWorkspaceRequest, title: String, task: String, now: Date = Date()) -> Workspace {
        var workspace = placeholder(for: request, existing: [], now: now)
        workspace.title = title
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
