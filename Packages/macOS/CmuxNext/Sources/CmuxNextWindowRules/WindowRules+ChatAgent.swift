/// The agent chat handlers' rules (cmux-window-rules `chat::agent`): the tables the agent actions bind from, where
/// New Agent Chat opens, Open File's checks, the agent chat zoom, the Memory Inspector's place and route, the model
/// picker's catalog and an agent-opened workspace's sidebar placement. Each method answers nil when the FFI does not.
extension WindowRules {
    /// The tables the agent chat handlers bind from.
    public nonisolated struct ChatAgentTables: Decodable, Equatable, Sendable {
        /// An agent chat page command a native row runs; `refusesRemote`: a remote chat refuses it.
        public struct PageCommand: Decodable, Equatable, Sendable {
            public var action: String
            public var command: String
            public var refusesRemote: Bool
        }

        /// A permission row's action and the page command it runs.
        public struct PermissionCommand: Decodable, Equatable, Sendable {
            public var action: String
            public var command: String
        }

        /// A copy action and the `_acpmux/session_files` kinds it copies, first match wins.
        public struct CopyFile: Decodable, Equatable, Sendable {
            public var action: String
            public var kinds: [String]
        }

        /// Launch Claude/Codex Teams: the action, the harness and the line typed into the new terminal.
        public struct TeamsLaunch: Decodable, Equatable, Sendable {
            public var action: String
            public var harness: String
            public var shellLine: String
        }

        public var pageCommands: [PageCommand]
        public var permissionCommands: [PermissionCommand]
        public var copyFiles: [CopyFile]
        public var teams: [TeamsLaunch]
        /// The protocol's effort names (Set Effort's suggestions).
        public var efforts: [String]
        /// The protocol's mode names (Set Mode's suggestions).
        public var modes: [String]
    }

    /// The tables, asked once per launch: they never change while the app runs.
    public static let chatAgentTables: ChatAgentTables? = WindowRules().call("window_chat_agent_tables", Empty(), as: ChatAgentTables.self)

    private struct Empty: Encodable {}

    /// The agent chat zoom after a step and the percent its indicator shows.
    public nonisolated struct ChatZoom: Decodable, Equatable, Sendable {
        public var zoom: Double
        public var percent: Int
    }

    /// `current` stepped by `delta`, clamped to `range` (`agentPane.zoom`).
    public func chatZoom(current: Double, delta: Double, range: ClosedRange<Double>) -> ChatZoom? {
        struct Request: Encodable { var current, delta, lower, upper: Double }
        return call("window_chat_agent_zoom", Request(current: current, delta: delta, lower: range.lowerBound, upper: range.upperBound),
                    as: ChatZoom.self)
    }

    /// Open File's first step.
    public nonisolated enum ChatFilePlace: Decodable, Equatable, Sendable {
        /// No path: the cmux picker.
        case picker
        /// A place outside the catalog's: refused.
        case invalidPlace(String)
        /// Open at `target` (`tab` or `editor`); `paneless`: the editor needs no pane, the file is this Mac's.
        case open(target: String, paneless: Bool)

        private enum CodingKeys: String, CodingKey { case decision, place, target, paneless }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .decision) {
            case "picker": self = .picker
            case "invalidPlace": self = .invalidPlace(try container.decode(String.self, forKey: .place))
            case "open": self = .open(target: try container.decode(String.self, forKey: .target),
                                      paneless: try container.decode(Bool.self, forKey: .paneless))
            case let other: throw DecodingError.dataCorruptedError(forKey: .decision, in: container, debugDescription: "file place \(other)")
            }
        }
    }

    /// Open File's first step for `path` and the invocation's `place` (`where`, nil when absent).
    public func chatFilePlace(path: String, place: String?, namesPane: Bool, hasFocusedPane: Bool) -> ChatFilePlace? {
        struct Request: Encodable { var path: String, place: String?, namesPane: Bool, hasFocusedPane: Bool }
        return call("window_chat_agent_file_place", Request(path: path, place: place, namesPane: namesPane, hasFocusedPane: hasFocusedPane),
                    as: ChatFilePlace.self)
    }

    /// Why Open File refuses a path before it reads the file.
    public nonisolated enum ChatFileRefusal: String, Decodable, Equatable, Sendable {
        /// Not an absolute path (or, on another machine, one with a NUL).
        case notAbsolute
        /// A file on another machine opens only as a tab.
        case remotePreview
    }

    /// Open File's path check on another machine (`remote`) or for a tab on this Mac. The outer nil: no answer; the
    /// inner nil: go on.
    public func chatFileCheck(path: String, target: String, remote: Bool) -> ChatFileRefusal?? {
        struct Request: Encodable { var path: String, target: String, remote: Bool }
        struct Reply: Decodable { var refusal: ChatFileRefusal? }
        return call("window_chat_agent_file_check", Request(path: path, target: target, remote: remote), as: Reply.self).map(\.refusal)
    }

    /// The pane a new agent chat opens in.
    public nonisolated enum ChatPaneRoute: String, Decodable, Equatable, Sendable {
        /// The invocation's pane.
        case open
        /// No pane: refused.
        case refuse
        /// Over a top page (Home): a new workspace whose only tab is the chat.
        case overTopPage
        /// No mounted pane yet: the workspace's first pane, then the chat there.
        case firstPane
    }

    /// Where a new chat opens: `targeted` (an explicit target), `hasPane` (the invocation's shown pane), `topPage`
    /// (the window shows one), `hasWorkspace` (the invocation's workspace).
    public func chatPaneRoute(targeted: Bool, hasPane: Bool, topPage: Bool, hasWorkspace: Bool) -> ChatPaneRoute? {
        struct Request: Encodable { var targeted, hasPane, topPage, hasWorkspace: Bool }
        struct Reply: Decodable { var route: ChatPaneRoute }
        return call("window_chat_agent_pane_route", Request(targeted: targeted, hasPane: hasPane, topPage: topPage, hasWorkspace: hasWorkspace),
                    as: Reply.self)?.route
    }

    /// How a chat machine is reached, as the composer's inventory lists it.
    public nonisolated enum ChatHostRoute: Encodable, Equatable, Sendable {
        case local
        case peer(String)
        case cloud(String)
        case pending

        private enum CodingKeys: String, CodingKey { case kind, peer, machine }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .local: try container.encode("local", forKey: .kind)
            case .peer(let peer):
                try container.encode("peer", forKey: .kind)
                try container.encode(peer, forKey: .peer)
            case .cloud(let machine):
                try container.encode("cloud", forKey: .kind)
                try container.encode(machine, forKey: .machine)
            case .pending: try container.encode("pending", forKey: .kind)
            }
        }
    }

    /// The facts of New Agent Chat on a resolved machine.
    public nonisolated struct ChatHostFacts: Encodable, Equatable, Sendable {
        public var route: ChatHostRoute
        public var ready: Bool
        public var cancelled: Bool
        /// The invocation names a pane or workspace, and whether it is on this Mac.
        public var targeted: Bool
        public var targetLocal: Bool
        /// The active window's machine is this Mac.
        public var activeLocal: Bool

        public init(route: ChatHostRoute, ready: Bool, cancelled: Bool, targeted: Bool, targetLocal: Bool, activeLocal: Bool) {
            self.route = route
            self.ready = ready
            self.cancelled = cancelled
            self.targeted = targeted
            self.targetLocal = targetLocal
            self.activeLocal = activeLocal
        }
    }

    /// What New Agent Chat on a machine does.
    public nonisolated enum ChatHostOpen: Decodable, Equatable, Sendable {
        /// Refused: `cancelled`, `notReady` or `noMachine`.
        case refuse(String)
        /// The active window shows another machine: this Mac's workspace it would focus takes the chat.
        case localPlacement
        /// The chat opens on this Cloud machine.
        case cloud(String)
        /// The chat opens in the invocation's local pane.
        case local

        private enum CodingKeys: String, CodingKey { case kind, reason, machine }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "refuse": self = .refuse(try container.decode(String.self, forKey: .reason))
            case "localPlacement": self = .localPlacement
            case "cloud": self = .cloud(try container.decode(String.self, forKey: .machine))
            case "local": self = .local
            case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "host open \(other)")
            }
        }
    }

    /// New Agent Chat on a machine: the `host` argument it runs with (nil: unchanged) and what it does.
    public nonisolated struct ChatHostPlan: Decodable, Equatable, Sendable {
        public var host: String?
        public var open: ChatHostOpen
    }

    public func chatHostPlan(_ facts: ChatHostFacts) -> ChatHostPlan? {
        call("window_chat_agent_host_plan", facts, as: ChatHostPlan.self)
    }

    /// What a script's New Agent Chat aimed at a pane or workspace does.
    public nonisolated enum ChatTargetedRoute: Decodable, Equatable, Sendable {
        /// Not this path.
        case skip
        /// The target names nothing.
        case notFound
        /// New Agent Chat's own placement in the shown pane.
        case inShown
        /// A tab on the workspace store in that pane, selected when no window shows it.
        case store(selects: Bool)

        private enum CodingKeys: String, CodingKey { case route, selects }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .route) {
            case "skip": self = .skip
            case "notFound": self = .notFound
            case "inShown": self = .inShown
            case "store": self = .store(selects: try container.decode(Bool.self, forKey: .selects))
            case let other: throw DecodingError.dataCorruptedError(forKey: .route, in: container, debugDescription: "targeted route \(other)")
            }
        }
    }

    /// `applies`: the target is a pane or workspace (`pane`: a pane); `found`: it names one; `shown`: a window shows
    /// its pane; `shownDocksChat`: that pane is a lone chat that docks; `allowsViewChange`: a person's run.
    public func chatTargetedRoute(applies: Bool, pane: Bool, found: Bool, shown: Bool, shownDocksChat: Bool,
                                  allowsViewChange: Bool) -> ChatTargetedRoute? {
        struct Request: Encodable { var applies, pane, found, shown, shownDocksChat, allowsViewChange: Bool }
        return call("window_chat_agent_targeted_route",
                    Request(applies: applies, pane: pane, found: found, shown: shown, shownDocksChat: shownDocksChat, allowsViewChange: allowsViewChange),
                    as: ChatTargetedRoute.self)
    }

    /// One column of the focused pane's screen (daemon pane handles), left to right; `dock`: docked to an edge.
    public nonisolated struct InspectorColumn: Encodable, Equatable, Sendable {
        public var panes: [UInt64]
        public var dock: Bool

        public init(panes: [UInt64], dock: Bool) {
            self.panes = panes
            self.dock = dock
        }
    }

    /// Where "Chief: Open Memory Inspector" puts its tab.
    public nonisolated enum InspectorPlacement: Decodable, Equatable, Sendable {
        /// A new tab in this pane (Home's right column).
        case tab(UInt64)
        /// A new column right of this pane's column.
        case newColumn(UInt64)

        private enum CodingKeys: String, CodingKey { case kind, pane }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let pane = try container.decode(UInt64.self, forKey: .pane)
            switch try container.decode(String.self, forKey: .kind) {
            case "tab": self = .tab(pane)
            case "newColumn": self = .newColumn(pane)
            case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "inspector \(other)")
            }
        }
    }

    /// The inspector's place while pane `focused` has focus; nil: Home has no scrolling column (or no answer), so a
    /// user workspace takes it.
    public func inspectorPlacement(focused: UInt64, inHome: Bool, columns: [InspectorColumn]) -> InspectorPlacement? {
        struct Request: Encodable { var focused: UInt64, inHome: Bool, columns: [InspectorColumn] }
        struct Reply: Decodable { var placement: InspectorPlacement? }
        return call("window_chat_agent_inspector_placement", Request(focused: focused, inHome: inHome, columns: columns), as: Reply.self)?
            .placement
    }

    /// A workspace as the inspector's anchor reads it: the home workspace, and whether its first screen has a pane.
    public nonisolated struct AnchorWorkspace: Encodable, Equatable, Sendable {
        public var home: Bool
        public var hasPane: Bool

        public init(home: Bool, hasPane: Bool) {
            self.home = home
            self.hasPane = hasPane
        }
    }

    /// The pane a new inspector column goes right of.
    public nonisolated enum InspectorAnchor: Decodable, Equatable, Sendable {
        /// The focused or targeted pane.
        case pane
        /// The last pane of the invocation's workspace.
        case scopeWorkspace
        /// The last pane of the machine's workspace at this index.
        case workspace(Int)
        /// No pane to anchor it.
        case refuse

        private enum CodingKeys: String, CodingKey { case kind, index }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "pane": self = .pane
            case "scopeWorkspace": self = .scopeWorkspace
            case "workspace": self = .workspace(try container.decode(Int.self, forKey: .index))
            case "refuse": self = .refuse
            case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "anchor \(other)")
            }
        }
    }

    /// `paneInHome`: the invocation's pane, true when it is in the home workspace (nil: none).
    public func inspectorAnchor(targeted: Bool, paneInHome: Bool?, scopeWorkspace: AnchorWorkspace?,
                                workspaces: [AnchorWorkspace]) -> InspectorAnchor? {
        struct Request: Encodable { var targeted: Bool, paneInHome: Bool?, scopeWorkspace: AnchorWorkspace?, workspaces: [AnchorWorkspace] }
        return call("window_chat_agent_inspector_anchor",
                    Request(targeted: targeted, paneInHome: paneInHome, scopeWorkspace: scopeWorkspace, workspaces: workspaces),
                    as: InspectorAnchor.self)
    }

    /// Which Chief a Memory Inspector tab shows.
    public nonisolated enum ChiefPlace: Decodable, Hashable, Sendable {
        /// A Chief this Mac runs; nil for its default Chief.
        case local(chief: String?)
        /// The Chief on a paired server.
        case server(machineID: String)

        private enum CodingKeys: String, CodingKey { case kind, chief, machineId }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "local": self = .local(chief: try container.decodeIfPresent(String.self, forKey: .chief))
            case "server": self = .server(machineID: try container.decode(String.self, forKey: .machineId))
            case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "chief \(other)")
            }
        }
    }

    /// The persisted route of `server`'s Chief, else Chief `chief` on this Mac, else this Mac's default Chief.
    public func memoryRoute(server: String?, chief: String?) -> String? {
        struct Request: Encodable { var server: String?, chief: String? }
        struct Reply: Decodable { var route: String }
        return call("window_chat_agent_memory_route", Request(server: server, chief: chief), as: Reply.self)?.route
    }

    /// The Chief a persisted route names; nil for a route this build cannot read (or no answer).
    public func memoryPlace(_ route: String) -> ChiefPlace? {
        struct Request: Encodable { var route: String }
        struct Reply: Decodable { var place: ChiefPlace? }
        return call("window_chat_agent_memory_place", Request(route: route), as: Reply.self)?.place
    }

    /// One harness's models as `_acpmux/models` lists them (`name` nil: the id is the title).
    public nonisolated struct HarnessModels: Encodable, Equatable, Sendable {
        public struct Model: Encodable, Equatable, Sendable {
            public var id: String
            public var name: String?

            public init(id: String, name: String?) {
                self.id = id
                self.name = name
            }
        }

        public var harness: String
        public var models: [Model]

        public init(harness: String, models: [Model]) {
            self.harness = harness
            self.models = models
        }
    }

    /// The Set Model picker's choices of one harness name, unsorted.
    public nonisolated struct HarnessChoices: Decodable, Equatable, Sendable {
        public struct Choice: Decodable, Equatable, Sendable {
            public var value: String
            public var title: String
        }

        public var harness: String
        public var models: [Choice]
    }

    /// The model picker's catalog by harness name, each harness also under its id's last `/` component (none when two
    /// harnesses share it).
    public func modelCatalog(_ harnesses: [HarnessModels]) -> [HarnessChoices]? {
        struct Request: Encodable { var harnesses: [HarnessModels] }
        struct Reply: Decodable { var harnesses: [HarnessChoices] }
        return call("window_chat_agent_model_catalog", Request(harnesses: harnesses), as: Reply.self)?.harnesses
    }

    /// Where an agent-opened workspace goes in the sidebar.
    public nonisolated struct SessionPlacement: Decodable, Equatable, Sendable {
        /// The default rule it takes; nil with a group.
        public enum DefaultSlot: String, Decodable, Equatable, Sendable { case top, newWorkspace }

        /// It joins its named group from its first frame.
        public var joinsGroup: Bool
        /// It goes below its caller's grouped row, when the caller has one.
        public var belowCaller: Bool
        public var defaultSlot: DefaultSlot?
    }

    public func sessionPlacement(group: Bool, top: Bool) -> SessionPlacement? {
        struct Request: Encodable { var group, top: Bool }
        return call("window_chat_agent_session_placement", Request(group: group, top: top), as: SessionPlacement.self)
    }
}
