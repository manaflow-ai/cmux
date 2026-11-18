import CmuxMobileDesign
import Foundation

// The normalized agent UI surface (`cmux.ui-surface/1`, plans/cmux-next/agent-ui-surfaces-DESIGN.md):
// what Rust (`cmux-tui/crates/cmux-ui-surfaces`) builds from A2UI messages or an MCP App resource and
// attaches to the tool call's row. The phone draws only this, with its own views; it never reads A2UI
// or MCP App markup. Every string is plain text. Input the model does not know draws as a `fallback`.

/// One agent UI surface, as Rust normalized it.
struct UISurface: Codable, Hashable, Sendable, Identifiable {
    static let schemaID = "cmux.ui-surface/1"

    var schema: String
    var surfaceId: String
    var source: Source
    var status: Status
    var error: String?
    var title: String?
    /// Absent while a streamed surface has no components yet.
    var root: Node?
    var frame: Frame?
    var pending: Pending?

    var id: String { surfaceId }

    init(surfaceId: String, source: Source, status: Status = .ready, error: String? = nil, title: String? = nil,
         root: Node? = nil, frame: Frame? = nil, pending: Pending? = nil) {
        schema = Self.schemaID
        self.surfaceId = surfaceId
        self.source = source
        self.status = status
        self.error = error
        self.title = title
        self.root = root
        self.frame = frame
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case schema, surfaceId, source, status, error, title, root, frame, pending }

    /// As leniently as the Mac's `readUiSurface`: only the schema and the surface id are required; a
    /// part of the wrong shape reads as absent.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        schema = try c.decode(String.self, forKey: .schema)
        surfaceId = try c.decode(String.self, forKey: .surfaceId)
        source = read(.source) ?? Source(kind: "a2ui")
        status = read(.status) ?? .ready
        error = read(.error)
        title = read(.title)
        root = read(.root)
        frame = read(.frame)
        pending = read(.pending)
    }

    struct Source: Codable, Hashable, Sendable {
        /// `a2ui` or `mcp-app`.
        var kind: String
        var server: String?
        var tool: String?
        var resourceUri: String?
        var catalogId: String?
        /// False: the server was not connected by the person, and the source line says "claimed"
        /// (DESIGN.md "Origin"; the Mac page reads the same `verified`).
        var verified: Bool?

        init(kind: String, server: String? = nil, tool: String? = nil, resourceUri: String? = nil, catalogId: String? = nil,
             verified: Bool? = nil) {
            self.kind = kind
            self.server = server
            self.tool = tool
            self.resourceUri = resourceUri
            self.catalogId = catalogId
            self.verified = verified
        }
    }

    enum Status: String, Codable, Hashable, Sendable {
        case streaming, ready, error

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .ready
        }
    }

    /// An MCP App's HTML view (the phone shows "open on Mac" in its place in this prototype).
    struct Frame: Codable, Hashable, Sendable {
        var html: String?
        var csp: String?
        var height: Double?
    }

    /// An action Rust holds until the person confirms it: the host-written summary and what it sends.
    struct Pending: Codable, Hashable, Sendable {
        var requestId: String
        var actionId: String
        var summary: String
        var sends: [Send]?
        /// `agent`, `tool:NAME` or `link:https://...`.
        var target: String?

        struct Send: Codable, Hashable, Sendable {
            var label: String
            var value: String
        }
    }

    struct A11y: Codable, Hashable, Sendable {
        var label: String?
        var description: String?
        /// `polite` or `assertive`: a change to the node is announced.
        var live: String?
        var hidden: Bool?
    }

    /// `{id, name, privileged}`: the renderer sends only the id (`uiSurfaceAction`).
    struct Action: Codable, Hashable, Sendable {
        var id: String
        var name: String?
        var privileged: Bool?
    }

    /// A field choice (`value`, `label`) or a review option (`id`, `label`, `detail`).
    struct Option: Codable, Hashable, Sendable {
        var id: String?
        var value: String?
        var label: String
        var detail: String?

        /// The key the option is chosen by.
        var key: String { value ?? id ?? label }
    }

    struct Fact: Codable, Hashable, Sendable {
        var label: String
        var value: String
    }

    struct Column: Codable, Hashable, Sendable {
        var key: String
        var label: String
        /// `start`, `center` or `end` (anything else is `start`).
        var align: String?
    }

    struct Series: Codable, Hashable, Sendable {
        var name: String
        var points: [Point]

        struct Point: Codable, Hashable, Sendable {
            /// A category or a value along x, as text (the chart labels it as it is).
            var x: String
            var y: Double

            private enum CodingKeys: String, CodingKey { case x, y }

            init(x: String, y: Double) {
                self.x = x
                self.y = y
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try? container.decode(String.self, forKey: .x) {
                    x = text
                } else {
                    let number = try container.decode(Double.self, forKey: .x)
                    x = number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
                }
                y = try container.decode(Double.self, forKey: .y)
            }
        }
    }

    enum NodeType: String, Sendable {
        case text, stack, card, list, divider, icon, image, button, field, approval, review, table, chart, progress, fallback
    }

    /// One node, with the wire's flat fields (each type reads its own, DESIGN.md "Nodes"). A field of
    /// the wrong JSON type reads as absent, so one bad value never drops the surface.
    struct Node: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var type: String
        var a11y: A11y?
        // text, fallback
        var text: String?
        /// `body`, `heading`, `caption`, `code`.
        var style: String?
        // stack, card, list
        /// `v` or `h`.
        var axis: String?
        var children: [Node]?
        // icon, image
        var name: String?
        var alt: String?
        // button, field, progress
        var label: String?
        var action: Action?
        /// `primary`, `secondary`, `danger`.
        var variant: String?
        // field
        /// `text`, `checkbox`, `choice`, `slider`, `date`.
        var input: String?
        var value: JSONValue?
        var options: [Option]?
        var multi: Bool?
        var min: Double?
        var max: Double?
        var bind: String?
        /// A text field whose value is obscured (a password).
        var secure: Bool?
        // approval, review
        var title: String?
        var detail: String?
        /// `low`, `medium`, `high`.
        var risk: String?
        var facts: [Fact]?
        var approve: Action?
        var deny: Action?
        var prompt: String?
        var submit: Action?
        // table
        var columns: [Column]?
        var rows: [[String]]?
        var truncated: Bool?
        // chart
        /// `bar`, `line`, `pie`.
        var kind: String?
        var series: [Series]?
        var yLabel: String?
        // progress
        /// `running`, `done`, `failed`.
        var state: String?

        var nodeType: NodeType? { NodeType(rawValue: type) }

        init(id: String, type: NodeType, text: String? = nil) {
            self.id = id
            self.type = type.rawValue
            self.text = text
        }

        private enum CodingKeys: String, CodingKey {
            case id, type, a11y, text, style, axis, children, name, alt, label, action, variant, input, value, options, multi,
                 min, max, bind, secure, title, detail, risk, facts, approve, deny, prompt, submit, columns, rows, truncated, kind,
                 series, yLabel, state
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func read<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
            id = read(.id) ?? UUID().uuidString
            type = read(.type) ?? NodeType.fallback.rawValue
            a11y = read(.a11y)
            text = read(.text)
            style = read(.style)
            axis = read(.axis)
            children = read(.children)
            name = read(.name)
            alt = read(.alt)
            label = read(.label)
            action = read(.action)
            variant = read(.variant)
            input = read(.input)
            value = read(.value)
            options = read(.options)
            multi = read(.multi)
            min = read(.min)
            max = read(.max)
            bind = read(.bind)
            secure = read(.secure)
            title = read(.title)
            detail = read(.detail)
            risk = read(.risk)
            facts = read(.facts)
            approve = read(.approve)
            deny = read(.deny)
            prompt = read(.prompt)
            submit = read(.submit)
            columns = read(.columns)
            rows = read(.rows)
            truncated = read(.truncated)
            kind = read(.kind)
            series = read(.series)
            yLabel = read(.yLabel)
            state = read(.state)
        }
    }
}

// MARK: - The decode point

extension UISurface {
    /// The surface a tool call's row carries, or nil. **The one place the phone reads it**: the call's
    /// `uiSurface`, which `ACPToolCall`'s decoder fills from the record (``meta(in:)``), else its
    /// `rawOutput`'s `_meta`. Retarget here if Rust puts it elsewhere. A value of another schema, or
    /// one that does not decode, is no surface.
    init?(_ call: ACPToolCall) {
        guard let raw = call.uiSurface ?? call.rawOutput?["_meta"].flatMap(Self.surface(inMeta:)) else { return nil }
        self.init(json: raw)
    }

    init?(json raw: JSONValue) {
        guard raw["schema"]?.stringValue == Self.schemaID, let surface = try? raw.decoded(as: UISurface.self) else { return nil }
        self = surface
    }

    /// The surface in the `_meta` of the value `decoder` reads (an ACP `tool_call` or `tool_call_update`
    /// as acpmux logs it). The row field `uiSurface` is read by the caller.
    static func meta(in decoder: any Decoder) -> JSONValue? {
        guard let container = try? decoder.container(keyedBy: MetaKey.self),
              let meta = (try? container.decodeIfPresent(JSONValue.self, forKey: .meta)) ?? nil else { return nil }
        return surface(inMeta: meta)
    }

    /// acpmux's tap writes it at `_meta.acpmux.uiSurface` (cmux-tui `acpmux/src/ui_surfaces.rs`
    /// `annotate`), the book's v1 row at `uiSurface`; `_meta.cmux.uiSurface` is read too.
    static func surface(inMeta meta: JSONValue) -> JSONValue? {
        meta["acpmux"]?["uiSurface"] ?? meta["cmux"]?["uiSurface"]
    }

    private enum MetaKey: String, CodingKey { case meta = "_meta" }

    /// Whether the person turned the cards on (`labs.agentUiSurfaces`, off by default). Off, a tool
    /// row that carries a surface draws as today.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        CmuxMobilePreferences.agentUiSurfaces(defaults)
    }
}

// MARK: - Reading

extension UISurface {
    /// The surface's binds with the values its fields start with (the renderer's held values before an edit).
    var initialValues: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        func walk(_ node: Node) {
            if node.nodeType == .field, let bind = node.bind, let value = node.value { out[bind] = value }
            if node.nodeType == .review, let bind = node.bind, let value = node.value { out[bind] = value }
            node.children?.forEach(walk)
        }
        if let root { walk(root) }
        return out
    }

    /// A guess at the card's height before its cell measures it (rows far from the reader).
    var estimatedHeight: Double {
        func height(_ node: Node) -> Double {
            switch node.nodeType {
            case .stack, .card, .list:
                let children = (node.children ?? []).map(height)
                return node.axis == "h" ? (children.max() ?? 0) : children.reduce(0, +) + Double(children.count) * 10
            case .table: return 40 + Double(node.rows?.count ?? 0) * 28
            case .chart: return 200
            case .approval: return 110 + Double(node.facts?.count ?? 0) * 22
            case .review: return 90 + Double(node.options?.count ?? 0) * 46
            case .field, .progress: return 64
            case .divider: return 9
            default: return 28
            }
        }
        return 60 + (root.map(height) ?? 0) + (frame == nil ? 0 : 70) + (pending == nil ? 0 : 150)
    }

    /// "quickstart · get-time": the server and tool the card came from.
    var sourceLine: String {
        [source.server, source.tool].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// The node an action id belongs to (the pending strip names its button).
    func node(withAction actionID: String) -> Node? {
        func find(_ node: Node) -> Node? {
            if [node.action, node.approve, node.deny, node.submit].contains(where: { $0?.id == actionID }) { return node }
            for child in node.children ?? [] {
                if let found = find(child) { return found }
            }
            return nil
        }
        return root.flatMap(find)
    }
}

extension JSONValue {
    /// The value as plain text (a field's value in a summary or an accessibility value).
    var uiSurfaceText: String {
        switch self {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .string(let value): value
        case .array(let values): values.map(\.uiSurfaceText).joined(separator: ", ")
        case .object: ""
        }
    }
}
