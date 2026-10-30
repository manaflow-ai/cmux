import Foundation

/// Wire shapes of the sidebar document (`sidebar.get`, the batches on
/// `session.events`). Tagged values are read in each form serde writes
/// (`"pinned"`, `{"type": "machine", ...}`, `{"kind": ...}`,
/// `{"machine": {...}}`), so the client does not depend on one of them.
nonisolated enum SidebarDocWire {
    struct Document: Decodable {
        var revision: Revision
        var sections: [Lossy<Section>]
        var items: [Lossy<Item>]

        enum CodingKeys: String, CodingKey { case revision, sections, items }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            revision = (try? c.decode(Revision.self, forKey: .revision)) ?? Revision(value: nil)
            sections = try c.decodeIfPresent([Lossy<Section>].self, forKey: .sections) ?? []
            items = try c.decodeIfPresent([Lossy<Item>].self, forKey: .items) ?? []
        }
    }

    struct Batch: Decodable {
        var revision: Revision?
        var changes: [Lossy<Change>]
    }

    struct Change: Decodable {
        var kind: String
        var resource: String
        var id: String
        var section: Section?
        var item: Item?

        enum CodingKeys: String, CodingKey { case kind, resource, id, value }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            resource = try c.decode(String.self, forKey: .resource)
            id = try c.decode(String.self, forKey: .id)
            if kind == "state_upsert" {
                if resource == "sidebar_section" { section = try? c.decode(Section.self, forKey: .value) }
                if resource == "sidebar_item" { item = try? c.decode(Item.self, forKey: .value) }
            }
        }
    }

    /// A decimal string, or a number from an older build.
    struct Revision: Decodable {
        var value: UInt64?

        init(value: UInt64?) { self.value = value }

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let text = try? c.decode(String.self) { value = UInt64(text, radix: 10) } else { value = try? c.decode(UInt64.self) }
        }
    }

    struct Section: Decodable {
        var id: String
        var kind: Tagged
        var title: String?
        var showsTitle: Bool?
        var region: SidebarRegion?
        var look: SectionLook?
        var arrangement: Arrangement?
        var columns: Int?
        /// Unknown names read as leading (as the reducer's own default).
        var align: String?
        var gap: Int?
        var room: String?
        var maxRows: Int?
        var keepsClosed: Bool?
        var hostGroup: Bool?

        enum CodingKeys: String, CodingKey {
            case id, kind, title, region, look, arrangement, columns, align, gap, room
            case showsTitle = "shows_title"
            case maxRows = "max_rows"
            case keepsClosed = "keeps_closed"
            case hostGroup = "host_group"
        }

        var record: SidebarDocSection {
            let kind: SidebarDocSectionKind = switch self.kind.tag {
            case "machine": .machine(session: self.kind.string("session_id") ?? Self.session(fromID: id))
            case "pinned": .pinned
            case "custom": .custom
            case "app": .app(contribution: self.kind.string("contribution"))
            case "builtin", "built_in": .builtin
            default: .other(self.kind.tag)
            }
            var arrangement = self.arrangement?.value ?? .list
            if let columns { arrangement.columns = columns }
            if let align { arrangement.align = SectionArrangement.Alignment(rawValue: align) ?? .leading }
            if let gap { arrangement.gap = gap }
            let pinned = kind == .pinned
            var record = SidebarDocSection(id: id, kind: kind, title: title, showsTitle: showsTitle ?? !pinned,
                                           region: region ?? (pinned ? .top : .middle), look: look ?? (pinned ? .builtIn : .list),
                                           arrangement: arrangement, room: room, maxRows: maxRows,
                                           keepsClosed: keepsClosed ?? (pinned || kind == .custom))
            record.hostGroup = (hostGroup ?? false) && record.session != nil
            return record
        }

        /// `sec_m_<session>` -> `<session>`.
        static func session(fromID id: String) -> String {
            id.hasPrefix("sec_m_") ? String(id.dropFirst("sec_m_".count)) : id
        }
    }

    /// An arrangement: the doc's layout name (`"grid"`), or the layout's object form.
    struct Arrangement: Decodable {
        var value: SectionArrangement

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let name = try? c.decode(String.self) {
                value = SectionArrangement(layout: SectionArrangement.Layout(rawValue: name) ?? .list)
            } else {
                value = try c.decode(SectionArrangement.self)
            }
        }
    }

    struct Item: Decodable {
        var id: String
        var section: String
        var parent: String?
        var body: Tagged
        var showsLabel: Bool?
        var span: Int?
        var label: String?
        /// Forward-compatible keys (the doc lane's explicit `extra`): `icon_url` until the url body carries it.
        var extra: AnyJSON?

        enum CodingKeys: String, CodingKey {
            case id, section, parent, body, span, label, extra
            case showsLabel = "shows_label"
        }

        var record: SidebarDocItem {
            let body: SidebarDocBody = switch self.body.tag {
            case "workspace":
                if let ref = self.body.workspaceRef { .workspace(ref) } else { .other("workspace") }
            case "group":
                .group(name: self.body.string("name") ?? "", color: self.body.string("color"), icon: self.body.string("icon"),
                       collapsed: self.body.bool("collapsed") ?? false)
            case "builtin", "built_in": .builtin(self.body.string("id") ?? "")
            case "app": .app(self.body.string("id") ?? "")
            case "url": .url(self.body.string("url") ?? "", title: self.body.string("title"))
            case "tab": .tab(self.body.string("ref") ?? self.body.string("id") ?? "")
            case "room": .room(self.body.string("id") ?? "")
            case "saved_group": .savedGroup(self.body.string("id") ?? "")
            case "ref": .ref(kind: self.body.string("kind") ?? "", value: self.body.string("value") ?? "")
            default: .other(self.body.tag)
            }
            return SidebarDocItem(id: id, section: section, parent: parent, body: body, showsLabel: showsLabel ?? true, span: span,
                                  label: label ?? self.body.string("label"), iconURL: self.body.string("icon_url") ?? (extra?.value as? [String: Any])?["icon_url"] as? String,
                                  pinnedInGroup: (extra?.value as? [String: Any])?["pinned"] as? Bool == true,
                                  archived: (extra?.value as? [String: Any])?["archived"] as? Bool == true,
                                  autoArchive: SidebarDocAutoArchiveRule(wire: (extra?.value as? [String: Any])?["auto_archive"]))
        }
    }

    /// A tagged value and its fields, whatever form the tag takes.
    struct Tagged: Decodable {
        var tag: String
        var fields: [String: Any] = [:]

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let text = try? c.decode(String.self) {
                tag = text
                return
            }
            let object = try c.decode(AnyJSON.self).value as? [String: Any] ?? [:]
            if let name = (object["type"] ?? object["kind"]) as? String {
                tag = name
                fields = object
            } else if object.count == 1, let (name, inner) = object.first {
                tag = name
                fields = inner as? [String: Any] ?? [:]
            } else {
                tag = ""
                fields = object
            }
        }

        func string(_ key: String) -> String? { fields[key] as? String }
        func bool(_ key: String) -> Bool? { fields[key] as? Bool }

        var workspaceRef: SidebarDocWorkspaceRef? {
            let ref = fields["ref"] as? [String: Any] ?? fields
            guard let session = ref["session_id"] as? String, let workspace = ref["workspace_id"] as? String else { return nil }
            return SidebarDocWorkspaceRef(sessionID: session, workspaceID: workspace)
        }
    }

    /// Any JSON value, as Foundation objects.
    struct AnyJSON: Decodable {
        var value: Any

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = NSNull() } else if let v = try? c.decode(Bool.self) { value = v } else if let v = try? c.decode(Double.self) {
                value = v
            } else if let v = try? c.decode(String.self) { value = v } else if let v = try? c.decode([AnyJSON].self) {
                value = v.map(\.value)
            } else { value = try c.decode([String: AnyJSON].self).mapValues(\.value) }
        }
    }

    /// A JSON value passed through unchanged (an inverse op list).
    indirect enum AnyJSONValue: Codable {
        case null, bool(Bool), number(Double), string(String), array([AnyJSONValue]), object([String: AnyJSONValue])

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null } else if let v = try? c.decode(Bool.self) { self = .bool(v) } else if let v = try? c.decode(Double.self) {
                self = .number(v)
            } else if let v = try? c.decode(String.self) { self = .string(v) } else if let v = try? c.decode([AnyJSONValue].self) {
                self = .array(v)
            } else { self = .object(try c.decode([String: AnyJSONValue].self)) }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }

    /// Decodes an element or skips it, so one unknown record keeps the rest.
    struct Lossy<T: Decodable>: Decodable {
        var value: T?

        init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
    }
}
