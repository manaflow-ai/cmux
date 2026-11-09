/// The workspace, screen and group verbs' rules (cmux-window-rules `workspaces`): bulk closes and
/// their question, the question each destructive action asks, description and status writes, a
/// workspace's directory, going to a group, a group's chain, screen closes and moves.
extension WindowRules {
    /// One bulk close of workspaces: how it finds what closes (`plan`: windowWorkspaces, allWindows,
    /// section, otherGroups, othersInGroup, aroundSelection), what it says when that is nothing, and
    /// whether it closes group by group.
    public nonisolated struct BulkClose: Decodable, Equatable, Sendable {
        public var id: String
        public var plan: String
        /// noOtherWorkspaces, noWorkspacesBelow, noWorkspacesAbove, noOtherWorkspacesInGroup; nil: runs.
        public var nothingToClose: String?
        public var byGroup: Bool
    }

    /// The bulk close `id` names, nil for any other action.
    public func bulkClose(_ id: String) -> BulkClose? {
        struct Request: Encodable { var id: String }
        struct Reply: Decodable { var close: BulkClose? }
        return call("window_workspace_bulk_close", Request(id: id), as: Reply.self)?.close
    }

    /// Every bulk close's action id.
    public func bulkCloseIDs() -> [String] {
        struct Request: Encodable {}
        struct Reply: Decodable { var ids: [String] }
        return call("window_workspace_bulk_close_ids", Request(), as: Reply.self)?.ids ?? []
    }

    /// The window (index into `windows`, each its workspaces) that keeps a workspace after `closing`
    /// closes, the active one first; nil when every window closes.
    public func survivor(active: Int?, windows: [[String]], closing: [String]) -> Int? {
        struct Request: Encodable { var active: Int?, windows: [[String]], closing: [String] }
        struct Reply: Decodable { var window: Int? }
        return call("window_workspace_survivor", Request(active: active, windows: windows, closing: closing), as: Reply.self)?.window
    }

    /// The one window that lists every closing row (`owners`: each row's window); `spans` when they span windows.
    public func rowsWindow(_ owners: [String?]) -> (spans: Bool, window: String?) {
        struct Request: Encodable { var owners: [String?] }
        struct Reply: Decodable { var spans: Bool, window: String? }
        guard let reply = call("window_workspace_rows_window", Request(owners: owners), as: Reply.self) else { return (true, nil) }
        return (reply.spans, reply.window)
    }

    /// The facts of a workspace close's question.
    public nonisolated struct CloseFacts: Encodable, Equatable, Sendable {
        public var count: Int
        /// The foreground programs the closing terminals run.
        public var programs: [String]
        /// No window stays open to show the undo toast.
        public var askWithoutUndo: Bool
        public var incognito: Bool
        /// The caller gives its own title.
        public var titled: Bool

        public init(count: Int, programs: [String], askWithoutUndo: Bool, incognito: Bool, titled: Bool) {
            self.count = count
            self.programs = programs
            self.askWithoutUndo = askWithoutUndo
            self.incognito = incognito
            self.titled = titled
        }
    }

    /// A workspace close's question.
    public nonisolated struct ClosePrompt: Decodable, Equatable, Sendable {
        public nonisolated enum Title: Decodable, Equatable, Sendable {
            case given, one, count(Int)

            private enum CodingKeys: String, CodingKey { case kind, count }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(String.self, forKey: .kind) {
                case "given": self = .given
                case "one": self = .one
                default: self = .count(try container.decode(Int.self, forKey: .count))
                }
            }
        }

        public nonisolated enum Body: Decodable, Equatable, Sendable {
            /// The programs still running, unique and sorted.
            case running([String])
            /// No window stays to undo it.
            case noUndo(incognito: Bool)

            private enum CodingKeys: String, CodingKey { case kind, programs, incognito }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if try container.decode(String.self, forKey: .kind) == "running" {
                    self = .running(try container.decode([String].self, forKey: .programs))
                } else {
                    self = .noUndo(incognito: try container.decode(Bool.self, forKey: .incognito))
                }
            }
        }

        public var title: Title
        public var body: Body
        /// "Don't ask again" turns `app.warnBeforeClosingTab` off.
        public var suppressesWarning: Bool
    }

    /// The question before a workspace close, or nil to close at once.
    public func closePrompt(_ facts: CloseFacts) -> ClosePrompt? {
        struct Reply: Decodable { var prompt: ClosePrompt? }
        return call("window_workspace_close_prompt", facts, as: Reply.self)?.prompt
    }

    /// The question a destructive action's run asks (the Cloud prompts are asked before this).
    public nonisolated enum Confirmation: String, Decodable, Sendable {
        case inHandler, groupWorkspaces, stash, bulkClose, browserProfileDelete, agentExtensions, spaceDelete,
             spaceClearDefaults, remoteInstall, updateRollback, tabGroupClose, killProcess, deleteChief, leaveConversation
        /// No question: the action runs.
        case noQuestion = "none"
    }

    /// The question action `id` asks; `stash`: the app's stash actions list it. Nil when the FFI does not answer.
    public func confirmation(_ id: String, stash: Bool) -> Confirmation? {
        struct Request: Encodable { var id: String, stash: Bool }
        struct Reply: Decodable { var confirmation: Confirmation }
        return call("window_workspace_confirmation", Request(id: id, stash: stash), as: Reply.self)?.confirmation
    }

    /// One field of `workspace.update`.
    public nonisolated enum FieldChange: Decodable, Equatable, Sendable {
        case unchanged, clear, set(String)

        private enum CodingKeys: String, CodingKey { case kind, value }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "clear": self = .clear
            case "set": self = .set(try container.decode(String.self, forKey: .value))
            default: self = .unchanged
            }
        }
    }

    /// A description or status action's run.
    public nonisolated enum NotesVerb: Sendable {
        case describe(String?), clearDescription, markDone, cycleStatus(current: String?), setStatus(String?)
    }

    /// What a description or status action writes, and the capabilities its fields need.
    public nonisolated struct NotesUpdate: Decodable, Equatable, Sendable {
        public var description: FieldChange
        public var taskStatus: FieldChange
        public var capabilities: [String]
    }

    /// The write of `verb`, or the status choices when its status is none of them (nil: the FFI does not answer).
    public func notes(_ verb: NotesVerb) -> Result<NotesUpdate, NotesChoices>? {
        struct Request: Encodable { var verb: String, text: String?, current: String?, status: String? }
        struct Reply: Decodable { var update: NotesUpdate?, choices: [String]? }
        let request = switch verb {
        case .describe(let text): Request(verb: "describe", text: text, current: nil, status: nil)
        case .clearDescription: Request(verb: "clearDescription", text: nil, current: nil, status: nil)
        case .markDone: Request(verb: "markDone", text: nil, current: nil, status: nil)
        case .cycleStatus(let current): Request(verb: "cycleStatus", text: nil, current: current, status: nil)
        case .setStatus(let status): Request(verb: "setStatus", text: nil, current: nil, status: status)
        }
        guard let reply = call("window_workspace_notes", request, as: Reply.self) else { return nil }
        if let update = reply.update { return .success(update) }
        return .failure(NotesChoices(choices: reply.choices ?? []))
    }

    /// The values Set Workspace Status takes, for its refusal.
    public nonisolated struct NotesChoices: Error, Equatable, Sendable {
        public var choices: [String]

        public init(choices: [String]) { self.choices = choices }
    }

    /// One tab, as a workspace's directory reads it.
    public nonisolated struct DirectoryTab: Encodable, Equatable, Sendable {
        public var id: String
        public var cwd: String?
        public var terminal: Bool

        public init(id: String, cwd: String?, terminal: Bool) {
            self.id = id
            self.cwd = cwd
            self.terminal = terminal
        }
    }

    /// A workspace's directory: the selected tab's while a window shows it, else its first tab's
    /// that reports one (`terminalsOnly`: terminal tabs only).
    public func directory(_ tabs: [DirectoryTab], selected: String?, terminalsOnly: Bool) -> String? {
        struct Request: Encodable { var tabs: [DirectoryTab], selected: String?, terminalsOnly: Bool }
        struct Reply: Decodable { var cwd: String? }
        return call("window_workspace_directory", Request(tabs: tabs, selected: selected, terminalsOnly: terminalsOnly), as: Reply.self)?.cwd
    }

    /// What going to a sidebar group does.
    public nonisolated struct FocusPlan: Decodable, Equatable, Sendable {
        /// The group is collapsed and opens.
        public var expands: Bool
        /// The workspace to show: its first not still being created.
        public var workspace: String?
        /// An empty saved group reopens.
        public var reopens: Bool

        public init(expands: Bool, workspace: String?, reopens: Bool) {
            self.expands = expands
            self.workspace = workspace
            self.reopens = reopens
        }
    }

    /// Going to a group of `workspaces` (id, still being created) with `items` other items.
    public func groupFocus(collapsed: Bool, pinned: Bool, workspaces: [(id: String, pending: Bool)], items: Int) -> FocusPlan? {
        struct Row: Encodable { var id: String, pending: Bool }
        struct Request: Encodable { var collapsed: Bool, pinned: Bool, workspaces: [Row], items: Int }
        let request = Request(collapsed: collapsed, pinned: pinned, workspaces: workspaces.map { Row(id: $0.id, pending: $0.pending) }, items: items)
        return call("window_workspace_group_focus", request, as: FocusPlan.self)
    }

    /// The groups from `start` out through each one's parent, innermost first, at most 16.
    public func groupChain(from start: String?, parents: [String: String?]) -> [String] {
        struct Request: Encodable { var start: String?, parents: [String: String?] }
        struct Reply: Decodable { var chain: [String] }
        return call("window_workspace_group_chain", Request(start: start, parents: parents), as: Reply.self)?.chain ?? []
    }

    /// Which screens a screen close verb takes.
    public nonisolated enum ScreenClose: String, Encodable, Sendable {
        case others, toRight, toLeft
    }

    /// The screens (indices) `verb` closes around screen `index`, by which are `pinned`.
    public func screenClose(_ verb: ScreenClose, index: Int, pinned: [Bool]) -> [Int] {
        struct Request: Encodable { var verb: ScreenClose, index: Int, pinned: [Bool] }
        struct Reply: Decodable { var close: [Int] }
        return call("window_workspace_screen_close", Request(verb: verb, index: index, pinned: pinned), as: Reply.self)?.close ?? []
    }

    /// Where Move Screen Left/Right puts screen `index`; nil at the edge.
    public func screenMove(_ index: Int, by offset: Int, count: Int) -> Int? {
        struct Request: Encodable { var index: Int, offset: Int, count: Int }
        return call("window_workspace_screen_move", Request(index: index, offset: offset, count: count), as: Index.self)?.index
    }

    /// Where Move Screen Group Left/Right puts `group` among `screens` (group, pinned); nil at the edge.
    public func screenGroupMove(_ group: String, forward: Bool, screens: [(group: String?, pinned: Bool)]) -> Int? {
        struct Screen: Encodable { var group: String?, pinned: Bool }
        struct Request: Encodable { var group: String, forward: Bool, screens: [Screen] }
        let request = Request(group: group, forward: forward, screens: screens.map { Screen(group: $0.group, pinned: $0.pinned) })
        return call("window_workspace_screen_group_move", request, as: Index.self)?.index
    }
}
