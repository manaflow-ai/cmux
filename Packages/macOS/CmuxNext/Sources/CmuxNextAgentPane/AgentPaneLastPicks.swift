/// The harness and model picked last (Leo 2026-10-11), for every folder and for the folder each was
/// picked in. The app keeps them because an agent page's own storage ends with the launch (its web
/// view's store is not persistent): the page sends each pick (`newTab.remember`) and the New Tab
/// context carries them back (`lastPicks`).
public nonisolated struct AgentPaneLastPicks: Codable, Sendable, Equatable {
    public nonisolated struct Pick: Codable, Sendable, Equatable {
        public var harness: String
        public var model: String

        public init(harness: String, model: String) {
            self.harness = harness
            self.model = model
        }
    }

    public nonisolated struct FolderPick: Codable, Sendable, Equatable {
        public var folder: String
        public var harness: String
        public var model: String

        public init(folder: String, harness: String, model: String) {
            self.folder = folder
            self.harness = harness
            self.model = model
        }
    }

    /// The folders kept; the oldest pick goes first.
    public static let maxFolders = 50

    public var global: Pick?
    /// Oldest first.
    public var folders: [FolderPick]

    public init(global: Pick? = nil, folders: [FolderPick] = []) {
        self.global = global
        self.folders = folders
    }

    /// The model a pick of an agent's own default names.
    public static let defaultModel = "default"

    /// The model last picked on `harness`: in `folder` first, then anywhere.
    public func lastModel(harness: String, folder: String?) -> String? {
        if let folder, let pick = folders.last(where: { $0.folder == folder }), pick.harness == harness {
            return pick.model
        }
        return global?.harness == harness ? global?.model : nil
    }

    /// Records `pick` for every folder and for `folder`.
    public mutating func record(_ pick: Pick, folder: String?) {
        global = pick
        guard let folder else { return }
        folders.removeAll { $0.folder == folder }
        folders.append(FolderPick(folder: folder, harness: pick.harness, model: pick.model))
        if folders.count > Self.maxFolders { folders.removeFirst(folders.count - Self.maxFolders) }
    }
}

/// What the page asks the app to remember (`newTab.remember`): the agent, and the model picked on it
/// in `folder` when the pick named one.
public nonisolated struct AgentPaneRememberedPick: Sendable, Equatable {
    public var agent: String
    public var model: String?
    public var folder: String?
    /// Integrate a harness was dismissed on the page, for every later page (`harnessHint: "dismissed"`).
    public var dismissesHarnessHint = false
    /// The person picked a project (or kept the page's) and sent a prompt there (`started`): later
    /// New Tab pages default to it (Leo 2026-10-21). Agents', CLI and socket chats never send it.
    public var started: String?

    public init(agent: String, model: String? = nil, folder: String? = nil) {
        self.agent = agent
        self.model = model
        self.folder = folder
    }
}
