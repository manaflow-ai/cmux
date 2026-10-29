#if DEBUG || CMUX_BENCH_HOOKS
/// The `agents` facet (schemas/oracle/snapshot-v1.schema.json): each agent chat tab's acpmux
/// session with what acpmux says of it (lane state, turn count, open permission requests), the hash of the
/// composer text the app keeps for it, and the conversation each Home Messages view shows. The host reads model
/// values in the snapshot's main-actor turn; this type only gives them the schema's shape. Private text never goes
/// in: a draft arrives as `sha256:<hex>`, and no prompt, reply or title is read at all, as Chromium's metrics
/// record a name's hash and never the name (base/metrics/metrics_hashes.cc, `HashMetricName`).
public struct OracleAgentsFacet: OracleFacetProvider {
    /// One agent chat tab and the session its store record names.
    public struct Session: Sendable, Hashable {
        /// acpmux's lane state for the session (`AgentActivityLane.State`), or `unknown` with no lane: no session
        /// yet, the watch down, or a chat whose acpmux this app does not mirror.
        public enum State: String, Sendable {
            case working, input, idle, failed, lost, unknown
        }

        public var tab: String
        public var workspace: String?
        /// The tab record's acpmux session; nil for a new chat before its first prompt.
        public var session: String?
        /// The harness (`claude`, `codex`, ...); nil while unknown.
        public var agent: String?
        public var state: State = .unknown
        /// acpmux's `turnCount`.
        public var turn = 0
        /// acpmux's `pendingPermissions`.
        public var pendingApprovals = 0
        /// `sha256:<hex>` of the composer text the app keeps for the tab; nil when it keeps none.
        public var draftSha256: String?

        /// What acpmux says of the session, from the app's lane mirror: the state's raw value and its counts.
        public struct Lane: Sendable, Hashable {
            public var state: String
            public var turns: Int
            public var pendingPermissions: Int

            public init(state: String, turns: Int, pendingPermissions: Int) {
                self.state = state
                self.turns = turns
                self.pendingPermissions = pendingPermissions
            }
        }

        public init(tab: String, workspace: String?, session: String?) {
            self.tab = tab
            self.workspace = workspace
            self.session = session
        }

        /// A row from the tab record and acpmux's lane for its session (unknown and 0 with none).
        public init(tab: String, workspace: String?, session: String?, agent: String?, lane: Lane?, draftSha256: String?) {
            self.init(tab: tab, workspace: workspace, session: session)
            self.agent = agent
            self.draftSha256 = draftSha256
            guard let lane else { return }
            state = State(rawValue: lane.state) ?? .unknown
            turn = max(0, lane.turns)
            pendingApprovals = max(0, lane.pendingPermissions)
        }

        /// The schema's object for this row.
        public var value: OracleValue {
            [
                "tab": .string(tab),
                "workspace": optional(workspace),
                "session": optional(session),
                "agent": optional(agent),
                "state": .string(state.rawValue),
                "turn": OracleValue(turn),
                "pendingApprovals": OracleValue(pendingApprovals),
                "draftSha256": optional(draftSha256),
            ]
        }
    }

    /// One Home Messages view: a window's Home top page (`window`) or a Home or docked Home tab (`tab`).
    public struct HomePage: Sendable, Hashable {
        public var window: String?
        public var tab: String?
        /// The conversation the view shows; nil on New Message, on a docked Home that shows Channels, or before one shows.
        public var conversation: String?

        public init(window: String? = nil, tab: String? = nil, conversation: String?) {
            self.window = window
            self.tab = tab
            self.conversation = conversation
        }

        public var value: OracleValue {
            ["window": optional(window), "tab": optional(tab), "conversation": optional(conversation)]
        }
    }

    /// One reading of the app's agent chats and Home views.
    public struct Reading: Sendable, Hashable {
        public var sessions: [Session]
        public var home: [HomePage]

        public init(sessions: [Session], home: [HomePage]) {
            self.sessions = sessions
            self.home = home
        }

        /// The facet's object.
        public var value: OracleValue {
            ["sessions": .array(sessions.map(\.value)), "home": .array(home.map(\.value))]
        }
    }

    public var facet: OracleFacet { .agents }
    public let capture: OracleFacetCapture

    /// - Parameter read: The agent chat tabs and Home views now, in the snapshot's main-actor turn; model values
    ///   only, no disk and no acpmux request. Nil when the host is gone, which answers not-comparable.
    public init(read: @escaping @MainActor @Sendable () -> Reading?) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            guard let reading = read() else {
                return .notComparable(reason: "the app services are gone", task: OracleFacet.agents.task)
            }
            return reading.value
        }
    }
}

private func optional(_ text: String?) -> OracleValue { text.map(OracleValue.string) ?? .null }
#endif
