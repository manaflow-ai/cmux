/// The harness and model picked last (Leo 2026-10-11), for every folder and for the folder each was
/// picked in. The app keeps them because an agent page's own storage ends with the launch (its web
/// view's store is not persistent): the page sends each pick (`newTab.remember`) and the New Tab
/// context carries them back (`lastPicks`).
public nonisolated struct AgentPaneLastPicks: Codable, Sendable, Equatable {
    public nonisolated struct Pick: Codable, Sendable, Equatable {
        public var harness: String
        public var model: String
        /// The level picked with it: only Cloud's pick (``cloud``) carries one, so a Cloud level comes back
        /// with its model. This Mac's level is its acpmux's saved default. nil is encoded as no key.
        public var effort: String?

        public init(harness: String, model: String, effort: String? = nil) {
            self.harness = harness
            self.model = model
            self.effort = effort
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
    /// The agent and model last picked for a Cloud machine: Cloud's own bucket, apart from this Mac's
    /// ``global`` and ``folders`` (Austin, 2026-11-27: "We should store a state for the local models and a
    /// different state for the cloud+autocloud"). A page sends it as `newTab.remember` with `place: "cloud"`.
    public var cloud: Pick?

    public init(global: Pick? = nil, folders: [FolderPick] = [], cloud: Pick? = nil) {
        self.global = global
        self.folders = folders
        self.cloud = cloud
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
    /// The person started a Cloud chat in this folder of this Mac or GitHub repository (`cloudStarted`,
    /// `github:owner/name`): later pages with Cloud picked default to it (cmux#53226).
    public var cloudStarted: String?
    /// The agent pick is for a Cloud machine (`place: "cloud"`): it is Cloud's last pick
    /// (``AgentPaneLastPicks/cloud``), never this Mac's.
    public var forCloud = false
    /// The level picked with a Cloud pick (`effort`, with `place: "cloud"`); nil keeps the level last
    /// picked on the same agent.
    public var effort: String?

    /// A folder (absolute) or a GitHub repository (`github:owner/name`), at most 4096 characters.
    public static func isCloudPick(_ value: String) -> Bool {
        guard value.count <= 4096 else { return false }
        if value.hasPrefix("/") { return true }
        return value.range(of: #"^github:[^/\s]+/[^/\s]+$"#, options: .regularExpression) != nil
    }

    public init(agent: String, model: String? = nil, folder: String? = nil) {
        self.agent = agent
        self.model = model
        self.folder = folder
    }
}
