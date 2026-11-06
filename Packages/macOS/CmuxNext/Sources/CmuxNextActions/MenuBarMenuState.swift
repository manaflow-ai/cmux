/// What the menu bar menu shows besides its fixed rows, read each time it opens: who is
/// signed in, how many agents work or wait, and whether a downloaded update waits.
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
    public init(account: Account? = nil, agentsWorking: Int = 0, agentsNeedingInput: Int = 0,
                updateReady: Bool = false, showsGlobalKey: Bool = false) {
        self.account = account
        self.agentsWorking = agentsWorking
        self.agentsNeedingInput = agentsNeedingInput
        self.updateReady = updateReady
        self.showsGlobalKey = showsGlobalKey
    }
}
