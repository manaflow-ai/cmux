/// The golden text of the six TypeEmitterTests shapes: what TypeEmitter writes for
/// cmux-tui/spec/fixtures/ipc-wire-types/sdk-schema.json. When the emitter changes on
/// purpose, the failing test prints the new text to paste here.
struct TypeEmitterGolden {
    static let tab = #"""
        public struct Tab: Codable, Sendable, Equatable {
            public var pinned: Bool
            public var `protocol`: UInt32?
            public var state: TabState?
            public var surface: SurfaceID
            public var terminalID: TerminalID?
            /// Shown in the tab.
            public var title: String?

            public init(pinned: Bool = false, `protocol`: UInt32? = nil, state: TabState? = TabState.idle, surface: SurfaceID, terminalID: TerminalID? = nil, title: String?) {
                self.pinned = pinned
                self.`protocol` = `protocol`
                self.state = state
                self.surface = surface
                self.terminalID = terminalID
                self.title = title
            }

            enum CodingKeys: String, CodingKey {
                case kind = "kind"
                case pinned = "pinned"
                case `protocol` = "protocol"
                case state = "state"
                case surface = "surface"
                case terminalID = "terminal_id"
                case terminalIDAlias0 = "terminal"
                case title = "title"
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try container.wireLiteral("tab", forKey: .kind, required: true)
                self.pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
                self.`protocol` = try container.decodeIfPresent(UInt32.self, forKey: .`protocol`)
                self.state = try container.contains(.state) ? container.decode(TabState?.self, forKey: .state) : TabState.idle
                self.surface = try container.decode(SurfaceID.self, forKey: .surface)
                self.terminalID = try container.decodeIfPresent(TerminalID.self, forKey: container.wireKey(.terminalID, .terminalIDAlias0))
                self.title = try container.decode(String?.self, forKey: .title)
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("tab", forKey: .kind)
                if self.pinned != false { try container.encode(self.pinned, forKey: .pinned) }
                try container.encodeIfPresent(self.`protocol`, forKey: .`protocol`)
                if self.state != TabState.idle { try container.encode(self.state, forKey: .state) }
                try container.encode(self.surface, forKey: .surface)
                try container.encodeIfPresent(self.terminalID, forKey: .terminalID)
                try container.encode(self.title, forKey: .title)
            }
        }
        """#

    static let sendMode = #"""
        public enum SendMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
            case paste = "paste"
            case `default` = "default"
        }
        """#

    static let tabState = #"""
        public enum TabState: RawRepresentable, Codable, Sendable, Equatable, Hashable {
            case idle
            case busyWait
            /// A value this build does not know, kept as written.
            case unknown(String)

            public init(rawValue: String) {
                switch rawValue {
                case "idle": self = .idle
                case "busy-wait": self = .busyWait
                default: self = .unknown(rawValue)
                }
            }

            public var rawValue: String {
                switch self {
                case .idle: "idle"
                case .busyWait: "busy-wait"
                case .unknown(let value): value
                }
            }

            public init(from decoder: any Decoder) throws {
                self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }
        """#

    static let node = #"""
        public indirect enum Node: Codable, Sendable, Equatable {
            case leaf(Leaf)
            case split(Split)
            /// A variant this build does not know, kept as written.
            case unknownVariant(tag: String, json: WireJSON)

            private enum TagKey: String, CodingKey {
                case tag = "type"
            }

            public init(from decoder: any Decoder) throws {
                let tag = try decoder.container(keyedBy: TagKey.self).decode(String.self, forKey: .tag)
                switch tag {
                case "leaf": self = .leaf(try Leaf(from: decoder))
                case "split": self = .split(try Split(from: decoder))
                default: self = .unknownVariant(tag: tag, json: try WireJSON(from: decoder))
                }
            }

            public func encode(to encoder: any Encoder) throws {
                switch self {
                case .leaf(let value): try value.encode(to: encoder)
                case .split(let value): try value.encode(to: encoder)
                case .unknownVariant(_, let json): try json.encode(to: encoder)
                }
            }

            public struct Leaf: Codable, Sendable, Equatable {
                public var pane: PaneID

                public init(pane: PaneID) {
                    self.pane = pane
                }

                enum CodingKeys: String, CodingKey {
                    case pane = "pane"
                    case type = "type"
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.pane = try container.decode(PaneID.self, forKey: .pane)
                    try container.wireLiteral("leaf", forKey: .type, required: true)
                }

                public func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.pane, forKey: .pane)
                    try container.encode("leaf", forKey: .type)
                }
            }

            public struct Split: Codable, Sendable, Equatable {
                public var a: Node
                public var b: Node

                public init(a: Node, b: Node) {
                    self.a = a
                    self.b = b
                }

                enum CodingKeys: String, CodingKey {
                    case a = "a"
                    case b = "b"
                    case type = "type"
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.a = try container.decode(Node.self, forKey: .a)
                    self.b = try container.decode(Node.self, forKey: .b)
                    try container.wireLiteral("split", forKey: .type, required: true)
                }

                public func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.a, forKey: .a)
                    try container.encode(self.b, forKey: .b)
                    try container.encode("split", forKey: .type)
                }
            }
        }
        """#

    static let entry = #"""
        public enum Entry: Codable, Sendable, Equatable {
            case liveEntry(LiveEntry)
            case deadEntry(DeadEntry)
            /// A value no variant of this build decodes, kept as written.
            case unknownVariant(WireJSON)

            /// The first variant, in schema order, that decodes the value.
            public init(from decoder: any Decoder) throws {
                if let value = try? LiveEntry(from: decoder) {
                    self = .liveEntry(value)
                    return
                }
                if let value = try? DeadEntry(from: decoder) {
                    self = .deadEntry(value)
                    return
                }
                self = .unknownVariant(try WireJSON(from: decoder))
            }

            public func encode(to encoder: any Encoder) throws {
                switch self {
                case .liveEntry(let value): try value.encode(to: encoder)
                case .deadEntry(let value): try value.encode(to: encoder)
                case .unknownVariant(let json): try json.encode(to: encoder)
                }
            }
        }
        """#

    static let bundle = #"""
        public struct Bundle: Codable, Sendable, Equatable {
            public var items: [ItemsItem]
            public var labels: [String: ColorHex]
            public var panes: [PaneID]
            public var raw: JsonValue?

            public init(items: [ItemsItem], labels: [String: ColorHex] = [:], panes: [PaneID], raw: JsonValue? = nil) {
                self.items = items
                self.labels = labels
                self.panes = panes
                self.raw = raw
            }

            enum CodingKeys: String, CodingKey {
                case items = "items"
                case labels = "labels"
                case panes = "panes"
                case raw = "raw"
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.items = try container.decode([ItemsItem].self, forKey: .items)
                self.labels = try container.decodeIfPresent([String: ColorHex].self, forKey: .labels) ?? [:]
                self.panes = try container.decode([PaneID].self, forKey: .panes)
                self.raw = try container.decodeIfPresent(JsonValue.self, forKey: .raw)
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(self.items, forKey: .items)
                if self.labels != [:] { try container.encode(self.labels, forKey: .labels) }
                try container.encode(self.panes, forKey: .panes)
                try container.encodeIfPresent(self.raw, forKey: .raw)
            }

            public struct ItemsItem: Codable, Sendable, Equatable {
                public var mode: Mode

                public init(mode: Mode = Mode.coarse) {
                    self.mode = mode
                }

                enum CodingKeys: String, CodingKey {
                    case mode = "mode"
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? Mode.coarse
                }

                public func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    if self.mode != Mode.coarse { try container.encode(self.mode, forKey: .mode) }
                }

                public enum Mode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
                    case coarse = "coarse"
                    case fine = "fine"
                }
            }
        }
        """#
}
