/// Where an agent chat, a tool opened from it and a column action go (cmux-window-rules `chat`).
extension WindowRules {
    /// A docked column, as the chat rules read it.
    public nonisolated struct ChatDock: Encodable, Equatable, Sendable {
        /// `agentChat` for the chat dock; nil for a plain dock.
        public var role: String?
        public var pinned: Bool
        public var allowsTabs: Bool

        public init(role: String?, pinned: Bool, allowsTabs: Bool) {
            self.role = role
            self.pinned = pinned
            self.allowsTabs = allowsTabs
        }
    }

    /// One column of a screen, in strip order.
    public nonisolated struct ChatColumn: Encodable, Equatable, Sendable {
        /// Its panes in tree order; the first is its top pane.
        public var panes: [String]
        public var dock: ChatDock?
        /// One pane holding one agent chat.
        public var loneChat: Bool

        public init(panes: [String], dock: ChatDock?, loneChat: Bool = false) {
            self.panes = panes
            self.dock = dock
            self.loneChat = loneChat
        }
    }

    /// A tab moving into the pane read (a group is never a chat).
    public nonisolated struct ChatMoving: Encodable, Equatable, Sendable {
        public var samePane: Bool
        public var chat: Bool

        public init(samePane: Bool, chat: Bool) {
            self.samePane = samePane
            self.chat = chat
        }
    }

    /// Where a person's new tab from a pane goes.
    public nonisolated enum ChatTabPlacement: Decodable, Equatable, Sendable {
        case here
        case tab(String)
        case dockChat
        case besideDock

        private enum CodingKeys: String, CodingKey { case placement, pane }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .placement) {
            case "here": self = .here
            case "tab": self = .tab(try container.decode(String.self, forKey: .pane))
            case "dockChat": self = .dockChat
            case "besideDock": self = .besideDock
            case let other: throw DecodingError.dataCorruptedError(forKey: .placement, in: container, debugDescription: "placement \(other)")
            }
        }
    }

    /// Where a new agent chat opens.
    public nonisolated enum NewChatPlace: Decodable, Equatable, Sendable {
        case here
        case dock(String)
        case newDock
        case besideDock

        private enum CodingKeys: String, CodingKey { case placement, pane }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .placement) {
            case "here": self = .here
            case "dock": self = .dock(try container.decode(String.self, forKey: .pane))
            case "newDock": self = .newDock
            case "besideDock": self = .besideDock
            case let other: throw DecodingError.dataCorruptedError(forKey: .placement, in: container, debugDescription: "new chat \(other)")
            }
        }
    }

    /// Every chat placement of one pane.
    public nonisolated struct ChatColumnRead: Decodable, Equatable, Sendable {
        public var placement: ChatTabPlacement
        public var newChat: NewChatPlace
        /// A person's New Tab page opens in the pane itself (the chat dock's top pane).
        public var keepsNewTabPage: Bool
        /// A pane Split Down made below the chat in the chat dock.
        public var belowChat: Bool
        /// The strip pane a pick on a New Tab page here opens in.
        public var pagePick: String?
        /// The pane's column is a chat dock (Home's included).
        public var chatDock: Bool
        public var takesOnlyChats: Bool
        /// Split Down of the pane grows its chat dock.
        public var splitsDown: Bool
        /// The chat dock refuses the moving tab.
        public var refusesMove: Bool
        /// The top pane of the screen's chat dock (not Home's pinned one).
        public var chatDockTop: String?
    }

    /// Every chat placement of `pane` on its screen's `columns`; nil when the FFI does not answer.
    public func chatColumn(pane: String, columns: [ChatColumn], recent: [String] = [], zoomed: Bool = false,
                           moving: ChatMoving? = nil) -> ChatColumnRead? {
        struct Request: Encodable { var pane: String, columns: [ChatColumn], recent: [String], zoomed: Bool, moving: ChatMoving? }
        return call("window_chat_column", Request(pane: pane, columns: columns, recent: recent, zoomed: zoomed, moving: moving),
                    as: ChatColumnRead.self)
    }

    /// A person's Cmd-I, as the app reads it.
    public nonisolated struct DockedOpen: Encodable, Equatable, Sendable {
        public var user: Bool
        public var targeted: Bool
        public var hasArguments: Bool
        public var canHost: Bool
        public var dockRoles: Bool
        public var pane: String
        /// The pane's ``chatColumn(pane:columns:recent:zoomed:moving:)`` read; nil when no screen shows it.
        public var shown: Bool
        public var chatDockTop: String?
        public var docksChat: Bool
        public var pendingDock: Bool

        public init(user: Bool, targeted: Bool, hasArguments: Bool, canHost: Bool, dockRoles: Bool, pane: String,
                    read: ChatColumnRead?, pendingDock: Bool) {
            (self.user, self.targeted, self.hasArguments, self.canHost, self.dockRoles) = (user, targeted, hasArguments, canHost, dockRoles)
            (self.pane, self.shown, self.chatDockTop) = (pane, read != nil, read?.chatDockTop)
            (self.docksChat, self.pendingDock) = (read?.placement == .dockChat, pendingDock)
        }
    }

    /// What Cmd-I does.
    public nonisolated enum DockedOpenDecision: Decodable, Equatable, Sendable {
        /// Not the docked chat's: the caller opens a chat tab in the pane.
        case notHandled
        case focus(String)
        /// The chat is on its way to its dock.
        case handled
        /// Open a new chat in the pane.
        case open

        private enum CodingKeys: String, CodingKey { case open, pane }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .open) {
            case "notHandled": self = .notHandled
            case "focus": self = .focus(try container.decode(String.self, forKey: .pane))
            case "handled": self = .handled
            case "open": self = .open
            case let other: throw DecodingError.dataCorruptedError(forKey: .open, in: container, debugDescription: "open \(other)")
            }
        }
    }

    public func dockedOpen(_ facts: DockedOpen) -> DockedOpenDecision? {
        call("window_chat_docked_open", facts, as: DockedOpenDecision.self)
    }

    /// A drop on a pane's edge: refused into the chat dock, a split, or measure the room first.
    public nonisolated enum DropSplit: String, Decodable, Sendable { case refusedChatDock, split, measure }

    /// The split decision of a drop on a pane's edge; nil when the FFI does not answer.
    public func dropSplit(roomDecided: Bool, intoChatDock: Bool) -> DropSplit? {
        struct Request: Encodable { var roomDecided: Bool, intoChatDock: Bool }
        struct Reply: Decodable { var split: DropSplit }
        return call("window_chat_drop", Request(roomDecided: roomDecided, intoChatDock: intoChatDock), as: Reply.self)?.split
    }

    /// The index of the pane a drop on a workspace lands in, given which panes are in the chat dock.
    public func dropPane(chatDocks: [Bool]) -> Int? {
        struct Request: Encodable { var chatDocks: [Bool] }
        struct Reply: Decodable { var pane: Int? }
        return call("window_chat_drop", Request(chatDocks: chatDocks), as: Reply.self)?.pane
    }

    /// A pane, as a chat's destination reads it.
    public nonisolated struct ChatPane: Encodable, Equatable, Sendable {
        public var id: String
        public var resourceId: String?
        public var focusedAt: UInt64

        public init(id: String, resourceId: String?, focusedAt: UInt64) {
            self.id = id
            self.resourceId = resourceId
            self.focusedAt = focusedAt
        }
    }

    /// A workspace, as a chat's destination reads it.
    public nonisolated struct ChatWorkspace: Encodable, Equatable, Sendable {
        public var id: String
        public var resourceId: String?
        public var key: String?
        public var panes: [ChatPane]

        public init(id: String, resourceId: String?, key: String?, panes: [ChatPane]) {
            self.id = id
            self.resourceId = resourceId
            self.key = key
            self.panes = panes
        }
    }

    /// A window, as a chat's destination reads it.
    public nonisolated struct ChatWindow: Encodable, Equatable, Sendable {
        public var workspace: String?
        public var recency: [String]
        public var focusWorkspace: String?
        public var focusedPane: String?
        public var remembered: [String: String]

        public init(workspace: String?, recency: [String], focusWorkspace: String?, focusedPane: String?, remembered: [String: String]) {
            (self.workspace, self.recency, self.focusWorkspace) = (workspace, recency, focusWorkspace)
            (self.focusedPane, self.remembered) = (focusedPane, remembered)
        }
    }

    /// A workspace (index into the request's) and a pane of it.
    public nonisolated struct ChatDestination: Decodable, Equatable, Sendable {
        public var workspace: Int
        public var pane: String
    }

    private struct DestinationReply: Decodable { var destination: ChatDestination? }

    /// A scripted chat's pane by the windows' focus (active window first); nil: none, or no answer.
    public func chatDestination(windows: [ChatWindow], workspaces: [ChatWorkspace]) -> ChatDestination? {
        struct Request: Encodable { var windows: [ChatWindow], workspaces: [ChatWorkspace] }
        return call("window_chat_destination", Request(windows: windows, workspaces: workspaces), as: DestinationReply.self)?.destination
    }

    /// The pane focused last across `workspaces` with a key.
    public func latestChatPane(_ workspaces: [ChatWorkspace]) -> ChatDestination? {
        struct Request: Encodable { var workspaces: [ChatWorkspace] }
        return call("window_chat_latest", Request(workspaces: workspaces), as: DestinationReply.self)?.destination
    }

    /// The pane a chat's target names (`kind` `pane` or `workspace`) in `workspaces`, every machine's in order.
    public func chatTarget(kind: String, id: String, workspaces: [ChatWorkspace]) -> ChatDestination? {
        struct Request: Encodable { var kind: String, id: String, workspaces: [ChatWorkspace] }
        return call("window_chat_target", Request(kind: kind, id: id, workspaces: workspaces), as: DestinationReply.self)?.destination
    }

    /// The folder a new chat starts in: `given`, the agent folder, else the selected tab's or the first tab's.
    public func chatCwd(given: String?, agentFolder: String?, tabs: [String?], selected: Int) -> String? {
        struct Request: Encodable { var given: String?, agentFolder: String?, tabs: [String?], selected: Int }
        struct Reply: Decodable { var cwd: String? }
        return call("window_chat_cwd", Request(given: given, agentFolder: agentFolder, tabs: tabs, selected: selected), as: Reply.self)?.cwd
    }
}

/// Column actions: their plans, availability and docking (cmux-window-rules `chat`).
extension WindowRules {
    /// The column and canvas action ids the app binds.
    public nonisolated struct ColumnActions: Decodable, Equatable, Sendable {
        public struct Canvas: Decodable, Equatable, Sendable {
            public var id: String
            public var arrangement: String
        }

        /// Planned by ``columnPlan(_:_:)``.
        public var planned: [String]
        /// Disabled on a screen's only column.
        public var loneColumnDisabled: [String]
        public var canvas: [Canvas]
    }

    public func columnActions() -> ColumnActions? {
        struct Request: Encodable {}
        return call("window_columns_actions", Request(), as: ColumnActions.self)
    }

    /// The column a column action runs on.
    public nonisolated struct ActionColumn: Encodable, Equatable, Sendable {
        public var width: Double
        public var panes: [String]
        /// The screen's implicit column: its only one.
        public var implicit: Bool
        public var docked: Bool

        public init(width: Double, panes: [String], implicit: Bool, docked: Bool) {
            (self.width, self.panes, self.implicit, self.docked) = (width, panes, implicit, docked)
        }
    }

    /// The facts a column action reads.
    public nonisolated struct ColumnFacts: Encodable, Equatable, Sendable {
        public var column: ActionColumn
        /// The panes of the column on the left and on the right, when there is one.
        public var left: [String]?
        public var right: [String]?
        public var recent: [String]
        public var focused: String?
        public var columnMove: Bool
        /// The column's first pane has a daemon handle.
        public var handle: Bool

        public init(column: ActionColumn, left: [String]?, right: [String]?, recent: [String], focused: String?,
                    columnMove: Bool, handle: Bool) {
            (self.column, self.left, self.right, self.recent) = (column, left, right, recent)
            (self.focused, self.columnMove, self.handle) = (focused, columnMove, handle)
        }
    }

    /// Why a column action does nothing.
    public nonisolated enum ColumnRefusal: Equatable, Sendable {
        case alreadyHasWidth
        case columnAtEdge
        /// `right` false: left.
        case noColumnInDirection(right: Bool)
        case needsColumnMove
        case noHandle
    }

    /// What a column action does.
    public nonisolated enum ColumnPlan: Decodable, Equatable, Sendable {
        case setWidth(Double)
        case moveColumn(right: Bool, pane: String)
        case swapPane(right: Bool, pane: String)
        case focus(String)
        case center(String)
        case refuse(ColumnRefusal, quiet: Bool)
        case nothing

        private enum CodingKeys: String, CodingKey { case plan, width, side, pane, refusal, quiet }
        private enum RefusalKeys: String, CodingKey { case reason, side }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let right = { try container.decode(String.self, forKey: .side) == "right" }
            switch try container.decode(String.self, forKey: .plan) {
            case "setWidth": self = .setWidth(try container.decode(Double.self, forKey: .width))
            case "moveColumn": self = .moveColumn(right: try right(), pane: try container.decode(String.self, forKey: .pane))
            case "swapPane": self = .swapPane(right: try right(), pane: try container.decode(String.self, forKey: .pane))
            case "focus": self = .focus(try container.decode(String.self, forKey: .pane))
            case "center": self = .center(try container.decode(String.self, forKey: .pane))
            case "refuse":
                let reason = try container.nestedContainer(keyedBy: RefusalKeys.self, forKey: .refusal)
                let refusal: ColumnRefusal = switch try reason.decode(String.self, forKey: .reason) {
                case "alreadyHasWidth": .alreadyHasWidth
                case "columnAtEdge": .columnAtEdge
                case "noColumnInDirection": .noColumnInDirection(right: try reason.decode(String.self, forKey: .side) == "right")
                case "needsColumnMove": .needsColumnMove
                case "noHandle": .noHandle
                case let other: throw DecodingError.dataCorruptedError(forKey: .reason, in: reason, debugDescription: "refusal \(other)")
                }
                self = .refuse(refusal, quiet: try container.decode(Bool.self, forKey: .quiet))
            case "nothing", "unknown": self = .nothing
            case let other: throw DecodingError.dataCorruptedError(forKey: .plan, in: container, debugDescription: "plan \(other)")
            }
        }
    }

    /// The plan of column action `action`; nil when the FFI does not answer.
    public func columnPlan(_ action: String, _ facts: ColumnFacts) -> ColumnPlan? {
        struct Request: Encodable {
            var action: String
            var facts: ColumnFacts
            func encode(to encoder: any Encoder) throws {
                try facts.encode(to: encoder)
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(action, forKey: .action)
            }
            enum Key: String, CodingKey { case action }
        }
        return call("window_columns_plan", Request(action: action, facts: facts), as: ColumnPlan.self)
    }

    /// Why a column action is disabled up front.
    public nonisolated enum ColumnUnavailable: String, Decodable, Sendable { case addSecondColumn, notDocked }

    /// Why `action` is disabled on `column`; nil: available, no column, or no answer.
    public func columnAvailability(_ action: String, column: ActionColumn?) -> ColumnUnavailable? {
        struct Request: Encodable { var action: String, column: ActionColumn? }
        struct Reply: Decodable { var unavailable: ColumnUnavailable? }
        return call("window_columns_availability", Request(action: action, column: column), as: Reply.self)?.unavailable
    }

    /// The daemon capability (its wire name) a dock change lacks; nil: send it (with no answer the daemon checks it).
    public func dockNeeds(band: Bool, dockColumns: Bool, edgeDocks: Bool) -> String? {
        struct Request: Encodable { var band: Bool, dockColumns: Bool, edgeDocks: Bool }
        struct Reply: Decodable { var needs: String? }
        return call("window_columns_dock", Request(band: band, dockColumns: dockColumns, edgeDocks: edgeDocks), as: Reply.self)?.needs
    }

    /// A lone column's focused tab moving into a new dock: the facts.
    public nonisolated struct DockMoveFacts: Encodable, Equatable, Sendable {
        public var pane: String
        public var paneTabs: Int
        public var columnPanes: [String]
        /// The column's other panes a window shows, in order.
        public var shownOthers: [String]
        public var hasTab: Bool
        public var edgeDocks: Bool
        public var tabColumnRespawn: Bool

        public init(pane: String, paneTabs: Int, columnPanes: [String], shownOthers: [String], hasTab: Bool,
                    edgeDocks: Bool, tabColumnRespawn: Bool) {
            (self.pane, self.paneTabs, self.columnPanes, self.shownOthers) = (pane, paneTabs, columnPanes, shownOthers)
            (self.hasTab, self.edgeDocks, self.tabColumnRespawn) = (hasTab, edgeDocks, tabColumnRespawn)
        }
    }

    /// How the focused tab moves into a new dock.
    public nonisolated enum DockMove: Decodable, Equatable, Sendable {
        /// The daemon lacks this capability (its wire name).
        case refuse(String)
        case noTab
        /// `respawn`: a fresh tab of its kind stays behind; `anchor` places the new column.
        case move(respawn: Bool, anchor: String)

        private enum CodingKeys: String, CodingKey { case move, needs, respawn, anchor }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .move) {
            case "refuse": self = .refuse(try container.decode(String.self, forKey: .needs))
            case "noTab": self = .noTab
            case "move": self = .move(respawn: try container.decode(Bool.self, forKey: .respawn),
                                      anchor: try container.decode(String.self, forKey: .anchor))
            case let other: throw DecodingError.dataCorruptedError(forKey: .move, in: container, debugDescription: "dock move \(other)")
            }
        }
    }

    public func dockMove(_ facts: DockMoveFacts) -> DockMove? {
        call("window_columns_dock_move", facts, as: DockMove.self)
    }
}
