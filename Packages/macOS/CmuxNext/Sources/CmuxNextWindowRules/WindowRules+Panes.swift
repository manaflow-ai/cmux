/// A split's plan, Auto Layout's direction, the tab bar refusals and the terminal tables
/// (cmux-window-rules `tabs::panes`). Directions are `left`, `right`, `up`, `down`; edges
/// `left`, `right`, `top`, `bottom`.
extension WindowRules {
    /// The folder facts of a new pane, each as the app read it.
    public nonisolated struct SplitFolders: Encodable, Equatable, Sendable {
        public var explicit, uninherited, inherited, selected, first: String?

        public init(explicit: String?, uninherited: String?, inherited: String?, selected: String?, first: String?) {
            self.explicit = explicit
            self.uninherited = uninherited
            self.inherited = inherited
            self.selected = selected
            self.first = first
        }
    }

    /// The facts of one split.
    public nonisolated struct SplitFacts: Encodable, Equatable, Sendable {
        public var direction: String
        public var folders: SplitFolders
        /// What the tool-split rule said: `split`, `refused`, `tab`, `besideDock`.
        public var tool: String
        public var page: Bool
        public var shown: Bool

        public init(direction: String, folders: SplitFolders, tool: String, page: Bool, shown: Bool) {
            self.direction = direction
            self.folders = folders
            self.tool = tool
            self.page = page
            self.shown = shown
        }
    }

    /// The plan of one split.
    public nonisolated struct SplitPlan: Decodable, Equatable, Sendable {
        /// `pageSplit`, `refuse`, `stripPage`, `stripTerminal`, `dockPage`, `dockColumn`, `split`.
        public var action: String
        public var edge: String
        public var horizontal: Bool
        /// `right` or `down`: the daemon splits only that way.
        public var daemonDirection: String
        /// Left and up swap the original toward this direction afterwards.
        public var swapTowards: String?
        public var splitAction: String
        public var cwd: String?
        public var tabCwd: String?

        private enum CodingKeys: String, CodingKey {
            case action = "do", edge, horizontal, daemonDirection, swapTowards, splitAction, cwd, tabCwd
        }
    }

    public func split(_ facts: SplitFacts) -> SplitPlan? {
        call("window_panes_split", facts, as: SplitPlan.self)
    }

    /// Auto Layout's direction for a new pane: the longer side, and the side that has room (nil: neither).
    public func autoDirection(width: Double, height: Double, roomRight: Bool, roomDown: Bool) -> (preferred: String, fitting: String?)? {
        struct Request: Encodable { var width: Double, height: Double, roomRight: Bool, roomDown: Bool }
        struct Reply: Decodable { var preferred: String, fitting: String? }
        return call("window_panes_auto_direction", Request(width: width, height: height, roomRight: roomRight, roomDown: roomDown), as: Reply.self)
            .map { ($0.preferred, $0.fitting) }
    }

    /// The refusals (`appPaneHasNoTabBar`, `chiefPaneHasNoTabBar`) of Hide/Show Tab Bar and New Horizontal Tab.
    public nonisolated struct TabBar: Decodable, Equatable, Sendable {
        public var toggle: String?
        public var newTab: String?
    }

    public func tabBar(appPane: Bool, pinnedDock: Bool, pinnedDockHidesTabBar: Bool) -> TabBar? {
        struct Request: Encodable { var appPane: Bool, pinnedDock: Bool, pinnedDockHidesTabBar: Bool }
        return call("window_panes_tab_bar", Request(appPane: appPane, pinnedDock: pinnedDock, pinnedDockHidesTabBar: pinnedDockHidesTabBar), as: TabBar.self)
    }

    /// The terminal actions that run one Ghostty binding action: (action id, binding).
    public func terminalBindings() -> [(action: String, binding: String)] {
        struct Empty: Encodable {}
        struct Reply: Decodable { var bindings: [[String]] }
        return (call("window_panes_terminal_bindings", Empty(), as: Reply.self)?.bindings ?? []).compactMap { pair in
            pair.count == 2 ? (action: pair[0], binding: pair[1]) : nil
        }
    }

    private nonisolated struct TextRequest: Encodable { var text: String }

    /// A Cmd-K clear's refusal without user content: the known reason it contains, else `other`.
    public func clearFailureKind(_ message: String) -> String {
        struct Reply: Decodable { var kind: String }
        return call("window_panes_clear_failure", TextRequest(text: message), as: Reply.self)?.kind ?? "other"
    }

    /// `path` as one single-quoted shell word; nil when the FFI does not answer.
    public func shellQuoted(_ path: String) -> String? {
        struct Reply: Decodable { var text: String }
        return call("window_panes_shell_quote", TextRequest(text: path), as: Reply.self)?.text
    }
}
