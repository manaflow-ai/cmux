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
public struct TaskAgentPick: Hashable, Sendable, Identifiable {
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

    public init(prompt: String = "", images: [TaskImage] = [], picks: [TaskAgentPick] = [], macID: String? = nil,
                directory: String? = nil, name: String = "") {
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
            let base = picks.count > 1 ? "\(draft.title) · \(pick.name ?? Self.agentTitle(pick.harness))" : draft.title
            let placeholder = Self.taskPlaceholder(for: request, title: Self.uniqueTitle(base, existing: titles), task: draft.title)
            titles.append(placeholder.title)
            var origin = draft
            // A pick of "" (the Mac's default agent) comes back as no pick.
            origin.picks = pick.harness.isEmpty ? [] : [pick]
            taskOrigins[placeholder.id] = origin
            begin(request, placeholder: placeholder, focus: picks.count == 1)
            made.append(placeholder)
        }
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

    /// A refused task workspace gives its draft back, once, when the composer is empty
    /// (the person did not start writing another task meanwhile).
    /// `reason`: the Mac's refusal when it is written for the person, shown in New Task.
    func restoreTaskDraft(after placeholderID: String, reason: String?) {
        guard let origin = taskOrigins.removeValue(forKey: placeholderID) else { return }
        var task = origin
        task.picks = []
        if taskDraft.isEmpty {
            // Only this agent comes back: the task's other agents may have started it already.
            taskDraft = origin
            restoredTask = task
        } else if restoredTask == task, taskDraftMatches(origin) {
            // Another agent of the same task failed too: it joins the draft given back.
            taskDraft.picks += origin.picks.filter { !taskDraft.picks.contains($0) }
        } else {
            return
        }
        refusedTaskIDs.insert(placeholderID)
        taskRefusal = reason?.isEmpty == false ? reason : "The Mac couldn't start this task. Check that cmux is running on it, then start it again."
    }

    /// Whether the composer holds `origin`'s task (its prompt, photos, name and place).
    private func taskDraftMatches(_ origin: TaskDraft) -> Bool {
        taskDraft.prompt == origin.prompt && taskDraft.images == origin.images && taskDraft.name == origin.name
            && taskDraft.macID == origin.macID && taskDraft.directory == origin.directory
    }

    /// Whether `placeholderID` was a New Task workspace the Mac refused (its draft is back).
    public func wasRefusedTask(_ placeholderID: String) -> Bool { refusedTaskIDs.contains(placeholderID) }

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
            // The tab is the agent (its chat names it so, "What should Claude do?"); the task is
            // what it works on, as a running chat's tab reads.
            workspace.tabs[0].title = agentTitle(harness)
            workspace.tabs[0].subtitle = task
            workspace.tabs[0].agentStatus = .working
        }
        return workspace
    }
}
