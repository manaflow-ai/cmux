/// What the menu bar menu shows besides its fixed rows, read each time it opens: Computer Use,
/// the Unread and Running chats, who is signed in, how many agents work or wait, and whether a
/// downloaded update waits.
///
/// The App fills it from Cloud auth, the daemon store and the updater (`MenuBarExtraHost`); tests
/// build one by hand.
///
/// ```swift
/// let state = MenuBarMenuState(account: .init(lines: ["Ada", "ada@example.com"], team: "Manaflow"),
///                              agentsWorking: 3, agentsNeedingInput: 1)
/// ```
public nonisolated struct MenuBarMenuState: Sendable, Hashable {
    /// The signed-in cmux account.
    public struct Account: Sendable, Hashable {
        /// The name, then the email when it differs; the first line carries the avatar.
        public var lines: [String]
        /// The selected team's name; its row opens the team picker.
        public var team: String?

        /// - Parameters:
        ///   - lines: Who is signed in, top to bottom.
        ///   - team: The selected team, nil without one.
        public init(lines: [String], team: String? = nil) {
            self.lines = lines
            self.team = team
        }
    }

    /// One agent chat in the Unread or Running list: the sidebar's name and harness.
    public struct Chat: Sendable, Hashable {
        /// The acpmux session id; a click opens the chat in its workspace.
        public var id: String
        /// The chat's title, as the sidebar names it.
        public var title: String
        /// The harness id (`claude-code`, `codex`), whose mark the row shows; nil draws the fallback.
        public var harness: String?

        public init(id: String, title: String, harness: String? = nil) {
            self.id = id
            self.title = title
            self.harness = harness
        }
    }

    /// The chats of one list, capped: the first ``MenuBarMenuSpec/chatLimit`` and how many more.
    public struct Chats: Sendable, Hashable {
        public var shown: [Chat]
        /// The chats past the cap; above 0 the list ends with More….
        public var more: Int

        public init(shown: [Chat] = [], more: Int = 0) {
            self.shown = shown
            self.more = more
        }

        /// The first `limit` of `chats` and the count of the rest.
        public init(_ chats: [Chat], limit: Int = MenuBarMenuSpec.chatLimit) {
            self.init(shown: Array(chats.prefix(limit)), more: max(0, chats.count - limit))
        }
    }

    /// Computer Use on this Mac: a session that drives an app, or the feature ready with none.
    public struct ComputerUse: Sendable, Hashable {
        /// The newest live session, nil when Computer Use is on and nothing drives an app.
        public var session: Session?

        /// A live session.
        public struct Session: Sendable, Hashable {
            public var id: String
            /// The app it drives (its name and bundle id), nil before its first act.
            public var appName: String?
            public var bundleID: String?
            /// The person took over: the agent waits until Hand Back.
            public var paused: Bool

            public init(id: String, appName: String? = nil, bundleID: String? = nil, paused: Bool = false) {
                self.id = id
                self.appName = appName
                self.bundleID = bundleID
                self.paused = paused
            }
        }

        public init(session: Session? = nil) {
            self.session = session
        }
    }

    /// Computer Use, nil when it is off or not set up: the menu then has no Computer Use row.
    public var computerUse: ComputerUse?
    /// The agent chats with a result nobody has read, newest first.
    public var unread: Chats
    /// The agent chats running a turn, newest first.
    public var running: Chats
    /// Nil when signed out: the menu offers Sign In instead.
    public var account: Account?
    /// This Mac's tabs whose agent runs a turn.
    public var agentsWorking: Int
    /// Tabs whose agent waits on the person (a permission, a question).
    public var agentsNeedingInput: Int
    /// A downloaded update waits: Restart to Update replaces Check for Updates.
    public var updateReady: Bool
    /// Show/Hide All Windows' system-wide key is on (`app.globalHotKey`): Open cmux shows it.
    public var showsGlobalKey: Bool

    /// - Parameters:
    ///   - account: The signed-in account, nil when signed out.
    ///   - agentsWorking: Agents running a turn; 0 hides the line.
    ///   - agentsNeedingInput: Agents waiting on the person; 0 hides the row.
    ///   - updateReady: A downloaded update waits for Restart to Update.
    ///   - showsGlobalKey: Open cmux shows the system-wide key.
    ///   - computerUse: Computer Use's row, nil for none.
    ///   - unread: The Unread list; empty hides the section.
    ///   - running: The Running list; empty hides the section.
    public init(account: Account? = nil, agentsWorking: Int = 0, agentsNeedingInput: Int = 0,
                updateReady: Bool = false, showsGlobalKey: Bool = false, computerUse: ComputerUse? = nil,
                unread: Chats = Chats(), running: Chats = Chats()) {
        self.computerUse = computerUse
        self.unread = unread
        self.running = running
        self.account = account
        self.agentsWorking = agentsWorking
        self.agentsNeedingInput = agentsNeedingInput
        self.updateReady = updateReady
        self.showsGlobalKey = showsGlobalKey
    }
}
