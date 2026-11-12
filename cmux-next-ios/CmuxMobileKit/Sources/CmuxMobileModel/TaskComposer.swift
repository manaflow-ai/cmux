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
            taskOrigins[placeholder.id] = draft
            begin(request, placeholder: placeholder, focus: picks.count == 1)
            made.append(placeholder)
        }
        taskDraft = TaskDraft(picks: draft.picks, macID: draft.macID, directory: draft.directory)
        return made
    }

    /// A refused task workspace gives its draft back, once, when the composer is empty
    /// (the person did not start writing another task meanwhile).
    func restoreTaskDraft(after placeholderID: String) {
        guard let draft = taskOrigins.removeValue(forKey: placeholderID) else { return }
        // Its siblings (the same task on other agents) don't give it back again.
        for (id, other) in taskOrigins where other == draft { taskOrigins[id] = nil }
        guard taskDraft.isEmpty else { return }
        taskDraft = draft
    }

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
            workspace.tabs[0].title = task
            workspace.tabs[0].subtitle = harness.isEmpty ? "Starting…" : "\(agentTitle(harness)) · Starting…"
            workspace.tabs[0].agentStatus = .working
        }
        return workspace
    }
}
