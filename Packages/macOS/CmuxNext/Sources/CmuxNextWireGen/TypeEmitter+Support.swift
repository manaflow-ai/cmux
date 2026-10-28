// TypeEmitter's support files: the typed ids, the opaque JSON
// value and the decoding helpers every generated file uses.

/// A typed id of the naming map. A scalar member is this id, not a bare integer
/// or string, when its wire name is one of `members` anywhere, or when its schema
/// location is one of `locations`: `Type.member`, with a tagged variant's tag or an
/// inline object's member in between (`Layout.stack.expanded`), and
/// `<command>.request.member` for a command's own request. So a pane's own `id`
/// and the `active_pane` of its screen are the same type, and a pane id cannot be
/// passed where a surface id is expected.
///
/// The ids mirror the app's (CmuxNextDaemon/Wire/Handles.swift and StringIDs.swift):
/// the same phantom-kind generics, kinds and conformances, under `Wire` names, so
/// CmuxNextDaemon can make its `DaemonHandle`, `HandleKind`, `DaemonStringID` and
/// `StringIDKind` aliases of these and every app id becomes the generated one.
struct WireIDType: Equatable {
    enum Storage: Equatable {
        /// `WireHandle<Kind>`: a UInt64 valid for one daemon generation.
        case handle
        /// `WireStringID<Kind>`: a durable string id.
        case durable

        var scalar: TypeSchema.Scalar { self == .handle ? .uint64 : .string }
        var generic: String { self == .handle ? "WireHandle" : "WireStringID" }
        var kinds: String { self == .handle ? "WireHandleKinds" : "WireStringIDKinds" }
    }

    /// The Swift type the generated code spells: `Wire` + the app's name.
    let name: String
    /// The phantom kind, a case-less enum in ``Storage/kinds``.
    let kind: String
    let storage: Storage
    let members: Set<String>
    let locations: Set<String>
    let summary: String

    private init(_ appName: String, _ storage: Storage, kind: String, members: Set<String> = [],
                 locations: Set<String> = [], _ summary: String) {
        name = "Wire" + appName
        self.kind = kind
        self.storage = storage
        self.members = members
        self.locations = locations
        self.summary = summary
    }

    static let all: [WireIDType] = [
        WireIDType("WorkspaceHandle", .handle, kind: "Workspace", members: ["workspace"], locations: ["Workspace.id"],
                   "A workspace's numeric handle, valid for one daemon generation. Use WireWorkspaceKey for identity."),
        WireIDType("ScreenID", .handle, kind: "Screen", members: ["screen", "screens"], locations: ["Screen.id"],
                   "A screen's numeric handle, valid for one daemon generation."),
        WireIDType("PaneID", .handle, kind: "Pane", members: ["pane", "panes", "active_pane", "zoomed_pane", "closes_panes"],
                   locations: ["LivePane.id", "DeadPane.id", "Layout.stack.expanded"],
                   "A pane's numeric handle, valid for one daemon generation."),
        WireIDType("SurfaceID", .handle, kind: "Surface", members: ["surface", "surfaces"],
                   locations: ["LivePane.active_tab", "TerminalResourcesResult.missing"],
                   "A tab's numeric handle (the protocol's `surface`), valid for one daemon generation."),
        WireIDType("SplitID", .handle, kind: "Split", members: ["split"],
                   "A split node's numeric handle, stable while the split exists."),
        WireIDType("ColumnID", .handle, kind: "Column", members: ["column"], "A viewport column's numeric handle."),
        WireIDType("RowID", .handle, kind: "Row", members: ["row"], "A row of a column; never reused."),
        WireIDType("NotificationID", .handle, kind: "Notification", members: ["notification"], "A notification's numeric handle."),
        WireIDType("ClientID", .handle, kind: "Client", members: ["client"], "A connected client's numeric handle."),
        WireIDType("WorkspaceKey", .durable, kind: "WorkspaceKey", members: ["workspace_key"],
                   locations: ["Workspace.key", "TerminalPlacement.key", "WorkspaceMutationResult.key"],
                   "Durable workspace identity: a lowercase canonical UUID."),
        WireIDType("TerminalID", .durable, kind: "Terminal", members: ["terminal_id", "terminal_ids", "expected_terminal_id"],
                   "A terminal's durable id (32 hex characters): it survives restarts and moves."),
        WireIDType("TerminalIncarnation", .durable, kind: "TerminalIncarnation", members: ["terminal_incarnation"],
                   "Changes each time a terminal's process is (re)spawned under the same id."),
        WireIDType("ResourceID", .durable, kind: "Resource",
                   "Durable resource identity of a machine, workspace, screen, pane, tab or terminal."),
        WireIDType("DaemonGeneration", .durable, kind: "Generation", members: ["generation"],
                   "The daemon's boot UUID: a change means every numeric handle is invalid."),
        WireIDType("WorkspaceGroupID", .durable, kind: "WorkspaceGroup", "A sidebar workspace group's id."),
        WireIDType("ClientTransactionID", .durable, kind: "ClientTransaction", "A client-chosen tab-drag transaction."),
        WireIDType("TabGroupID", .durable, kind: "TabGroup", locations: ["TabGroupRecord.id"], "A tab group's id."),
        WireIDType("SavedTabGroupID", .durable, kind: "SavedTabGroup", members: ["saved_id"],
                   locations: ["SavedTabGroupRecord.id"], "A session-wide saved tab group's id."),
        WireIDType("ProfileID", .durable, kind: "Profile", "A profile's id; `default` is the built-in profile."),
        WireIDType("BrowserProfileKey", .durable, kind: "BrowserProfile", members: ["browser_profile_id"],
                   "A browser profile's id; `default` is the built-in browser profile."),
        WireIDType("ScreenGroupID", .durable, kind: "ScreenGroup", "A screen group's id."),
        WireIDType("SavedScreenGroupID", .durable, kind: "SavedScreenGroup", "A saved screen group's id."),
    ]

    /// Every Swift name the id support files declare.
    static var declaredNames: [String] {
        all.map(\.name) + ["WireHandle", "WireHandleKind", "WireHandleKinds", "WireStringID", "WireStringIDKind", "WireStringIDKinds"]
    }

    /// The schema location of the member at JSON path `path` (`$.types.Layout.variants.stack.fields.expanded`
    /// is `Layout.stack.expanded`, `$.commands.split.request.fields.pane` is `split.request.pane`).
    static func location(ofMemberAt path: String) -> String {
        var location = path
        for prefix in ["$.types.", "$.commands.", "$.events."] where location.hasPrefix(prefix) {
            location.removeFirst(prefix.count)
        }
        return location.replacingOccurrences(of: ".variants.", with: ".").replacingOccurrences(of: ".fields.", with: ".")
    }

    /// The id the member `member` of type `scalar` at JSON path `path` holds, if the map names one:
    /// its location first, then its wire name.
    static func forMember(_ member: String?, at path: String, scalar: TypeSchema.Scalar) -> WireIDType? {
        guard let member else { return nil }
        let location = location(ofMemberAt: path)
        let candidates = all.filter { $0.storage.scalar == scalar }
        return candidates.first { $0.locations.contains(location) } ?? candidates.first { $0.members.contains(member) }
    }
}

extension TypeEmitter {
    /// The support files' sources, in ``WireTypeFiles/supportFileNames`` order: the same bytes for every schema.
    static func supportSources() -> [GeneratedSource] {
        zip(WireTypeFiles.supportFileNames, [idSource(.handle), idSource(.durable), jsonSource()]).map {
            GeneratedSource(fileName: $0, text: $1)
        }
    }

    private static func idSource(_ storage: WireIDType.Storage) -> String {
        let handle = storage == .handle
        let raw = storage.scalar.swiftName
        let protocolName = storage.generic + "Kind"
        let literalInit = handle
            ? "public init(integerLiteral value: UInt64) { self.init(rawValue: value) }"
            : "public init(stringLiteral value: String) { self.init(rawValue: value) }"
        var out = header(handle
            ? "Numeric daemon handles: valid for one daemon generation, typed by a phantom kind"
            : "Durable string ids: they survive daemon restarts, typed by a phantom kind")
        out += """

        /// Marker for the entity \(handle ? "a numeric handle" : "a durable string id") names.
        public protocol \(protocolName): Sendable {}

        public struct \(storage.generic)<Kind: \(protocolName)>: RawRepresentable, Hashable, Sendable, Codable,\(handle ? " Comparable," : "")
            CustomStringConvertible, \(handle ? "ExpressibleByIntegerLiteral" : "ExpressibleByStringLiteral") {
            public let rawValue: \(raw)

            public init(rawValue: \(raw)) { self.rawValue = rawValue }
            \(literalInit)


        """
        if handle {
            out += """
                public init(from decoder: any Decoder) throws {
                    self.init(rawValue: try decoder.singleValueContainer().decode(UInt64.self))
                }

            """
        } else {
            out += """
                /// Accepts a JSON number too, so an unexpected numeric id never fails the enclosing value.
                public init(from decoder: any Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let number = try? container.decode(UInt64.self) {
                        self.init(rawValue: String(number))
                    } else {
                        self.init(rawValue: try container.decode(String.self))
                    }
                }

            """
        }
        out += """

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }


        """
        if handle {
            out += "    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }\n"
        }
        out += "    public var description: String { \(handle ? "String(rawValue)" : "rawValue") }\n}\n\n"
        let ids = WireIDType.all.filter { $0.storage == storage }
        out += "/// The kinds, one case-less enum each.\npublic enum \(storage.kinds) {\n"
        for id in ids {
            out += "    public enum \(id.kind): \(protocolName) {}\n"
        }
        out += "}\n"
        for id in ids {
            out += "\n/// \(id.summary)\npublic typealias \(id.name) = \(storage.generic)<\(storage.kinds).\(id.kind)>\n"
        }
        return out
    }

    private static func jsonSource() -> String {
        header("Opaque JSON and the decoding helpers of the generated types") + """

        /// A JSON value the schema leaves open (`opaque_json`), or a variant this
        /// build does not know. Integers stay integers, so ids round-trip exactly.
        public enum \(wireJSON): Codable, Sendable, Equatable {
            case null
            case bool(Bool)
            case integer(Int64)
            case unsignedInteger(UInt64)
            case number(Double)
            case string(String)
            case array([\(wireJSON)])
            case object([String: \(wireJSON)])

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() {
                    self = .null
                } else if let value = try? container.decode(Bool.self) {
                    self = .bool(value)
                } else if let value = try? container.decode(Int64.self) {
                    self = .integer(value)
                } else if let value = try? container.decode(UInt64.self) {
                    self = .unsignedInteger(value)
                } else if let value = try? container.decode(Double.self) {
                    self = .number(value)
                } else if let value = try? container.decode(String.self) {
                    self = .string(value)
                } else if let value = try? container.decode([\(wireJSON)].self) {
                    self = .array(value)
                } else {
                    self = .object(try container.decode([String: \(wireJSON)].self))
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .null: try container.encodeNil()
                case .bool(let value): try container.encode(value)
                case .integer(let value): try container.encode(value)
                case .unsignedInteger(let value): try container.encode(value)
                case .number(let value): try container.encode(value)
                case .string(let value): try container.encode(value)
                case .array(let value): try container.encode(value)
                case .object(let value): try container.encode(value)
                }
            }
        }

        /// Any member name: the keys of an object type with no members (it still
        /// decodes only an object and encodes as `{}`) and of an untagged union's
        /// variant test.
        struct \(anyKey): CodingKey {
            let stringValue: String
            let intValue: Int?

            init(_ name: String) {
                stringValue = name
                intValue = nil
            }

            init?(stringValue: String) {
                self.init(stringValue)
            }

            init?(intValue: Int) {
                stringValue = String(intValue)
                self.intValue = intValue
            }
        }

        extension KeyedDecodingContainer {
            /// The first of a member's wire names (its name, then its aliases) that is present.
            func wireKey(_ first: Key, _ aliases: Key...) -> Key {
                aliases.first { !contains(first) && contains($0) } ?? first
            }

            /// Checks a literal member: present (or `required`) means equal to `constant`.
            func wireLiteral<Value: Decodable & Equatable & Sendable>(
                _ constant: Value,
                forKey key: Key,
                required: Bool
            ) throws {
                guard required || contains(key) else { return }
                let value = try decode(Value.self, forKey: key)
                guard value == constant else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: self, debugDescription: "expected \\(constant), got \\(value)")
                }
            }
        }

        extension KeyedDecodingContainer where Key == \(anyKey) {
            /// Whether a member is present under one of its wire names (its name, then its aliases).
            func wireHas(_ names: String...) -> Bool {
                names.contains { self.contains(\(anyKey)($0)) }
            }

            /// Whether a literal member is absent or, under the first of its wire names
            /// that is present, equal to `constant`.
            func wireLiteralHolds<Value: Decodable & Equatable>(_ constant: Value, _ names: String...) -> Bool {
                for name in names where self.contains(\(anyKey)(name)) {
                    return (try? decode(Value.self, forKey: \(anyKey)(name))) == constant
                }
                return true
            }
        }

        """
    }
}
