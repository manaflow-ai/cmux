import CCmuxLayoutReducerFFI
@testable import CmuxNextSidebar
import Foundation

/// Tests build a projection from records and the rows they draw. The app has the reducer regroup the rows
/// (`SidebarMirror.projection`, cmux-layout-reducer `sidebar_doc::project`), so this does the same: it writes
/// `records` as a sidebar document in the rows' order, loads it into a real mirror, views it over the workspaces the
/// rows show as open (an unplaced row's too) and maps the reducer's reply. A row whose item has no record (a change
/// the mirror would hold before its echo) places its workspace there.
extension SidebarDocProjection {
    nonisolated init(rows: [SidebarDocRow], records: SidebarDocRecords, revision: UInt64) {
        let document = SidebarDocTestDocument(rows: rows, records: records, revision: revision).json
        let live = rows.compactMap { $0.dimmed ? nil : $0.ref }
        let request = (try? JSONEncoder().encode(SidebarViewRequest(live: live))) ?? Data()
        let mirror = cmux_sidebar_mirror_new()
        defer { cmux_sidebar_mirror_free(mirror) }
        func call(_ entry: (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> UnsafeMutablePointer<CChar>?, _ body: Data) -> Data {
            guard let text = body.withUnsafeBytes({ entry(mirror, $0.bindMemory(to: UInt8.self).baseAddress, body.count) }) else { return Data() }
            defer { cmux_sidebar_mirror_string_free(text) }
            return Data(bytes: text, count: strlen(text))
        }
        _ = call(cmux_sidebar_mirror_load, document)
        let reply = call(cmux_sidebar_mirror_project, request)
        let wire = (try? JSONDecoder().decode(SidebarDocWire.Projection.self, from: reply))
            ?? SidebarDocWire.Projection(sections: [], machines: [:], items: [], machineSections: [:], machineOrder: [], unplaced: [],
                                         bandGroups: [], hostGroups: [], archived: [], groupSorts: [:], pinnedInGroup: [])
        self.init(wire: wire, revision: revision)
    }
}

/// `records` as a `sidebar-doc-v1` document, ordered as `rows` list them (records no row lists come after, by id).
nonisolated struct SidebarDocTestDocument {
    var rows: [SidebarDocRow]
    var records: SidebarDocRecords
    var revision: UInt64

    var json: Data {
        var itemOrder: [String: Int] = [:]
        var sectionOrder: [String: Int] = [:]
        var items = records.items
        let archivedRows = Set(rows.filter(\.archived).compactMap(\.item))
        for row in rows {
            if sectionOrder[row.section] == nil { sectionOrder[row.section] = sectionOrder.count }
            guard let id = row.item else { continue }
            if itemOrder[id] == nil { itemOrder[id] = itemOrder.count }
            if items[id] == nil, let ref = row.ref {
                items[id] = SidebarDocItem(id: id, section: row.section, parent: row.depth > 0 ? row.parent : nil, body: .workspace(ref))
            }
            // A row drawn archived whose parent row is not: the item itself is archived (the reducer marks the rest).
            if row.archived, !(row.parent.map(archivedRows.contains) ?? false) { items[id]?.archived = true }
        }
        let laterItems = items.keys.filter { itemOrder[$0] == nil }.sorted()
        for id in laterItems { itemOrder[id] = itemOrder.count }
        let laterSections = records.sections.keys.filter { sectionOrder[$0] == nil }.sorted()
        for id in laterSections { sectionOrder[id] = sectionOrder.count }
        var sections = records.sections
        // A row's machine section the records lack: the reducer's own stand-in, made a stored one here.
        for row in rows where sections[row.section] == nil && row.section.hasPrefix(SidebarDocStore.machineSectionPrefix) {
            sections[row.section] = SidebarDocSection(id: row.section,
                                                      kind: .machine(session: String(row.section.dropFirst(SidebarDocStore.machineSectionPrefix.count))))
        }
        let document: [String: Any] = [
            "revision": String(revision),
            "sections": sections.values.map { Self.section($0, order: sectionOrder[$0.id] ?? 0) },
            "items": items.values.map { Self.item($0, order: itemOrder[$0.id] ?? 0) },
        ]
        return (try? JSONSerialization.data(withJSONObject: document)) ?? Data()
    }

    private static func key(_ index: Int) -> String { "k" + String(format: "%06d", index) }

    private static func section(_ section: SidebarDocSection, order: Int) -> [String: Any] {
        let kind: [String: Any] = switch section.kind {
        case let .machine(session): ["type": "machine", "session_id": session]
        case .pinned: ["type": "pinned"]
        case .custom, .other: ["type": "custom"]
        case let .app(contribution): ["type": "app", "contribution": contribution ?? ""]
        case .builtin: ["type": "builtin"]
        }
        var wire: [String: Any] = [
            "id": section.id, "kind": kind, "shows_title": section.showsTitle, "region": section.region.rawValue,
            "look": section.look.rawValue, "arrangement": section.arrangement.layout.rawValue, "align": section.arrangement.align.rawValue,
            "keeps_closed": section.keepsClosed, "host_group": section.hostGroup, "order": key(order),
        ]
        if let title = section.title { wire["title"] = title }
        if let gap = section.arrangement.gap { wire["gap"] = gap }
        if let room = section.room { wire["room"] = room }
        if let maxRows = section.maxRows { wire["max_rows"] = maxRows }
        return wire
    }

    private static func item(_ item: SidebarDocItem, order: Int) -> [String: Any] {
        var extra: [String: Any] = [:]
        let body: [String: Any]
        switch item.body {
        case let .workspace(ref): body = ["type": "workspace", "ref": ["session_id": ref.sessionID, "workspace_id": ref.workspaceID]]
        case let .group(name, color, icon, collapsed):
            var group: [String: Any] = ["type": "group", "name": name, "collapsed": collapsed]
            if let color { group["color"] = color }
            if let icon { group["icon"] = icon }
            if let room = item.room { group["profile"] = room }
            body = group
        case let .builtin(id): body = ["type": "builtin", "id": id]
        case let .app(id): body = ["type": "app", "id": id]
        case let .url(url, title):
            var link: [String: Any] = ["type": "url", "url": url]
            if let title { link["title"] = title }
            if let icon = item.iconURL { link["icon_url"] = icon }
            body = link
        case let .tab(ref): body = ["type": "tab", "ref": ref]
        case let .room(id): body = ["type": "room", "id": id]
        case let .savedGroup(id): body = ["type": "saved_group", "id": id]
        case let .ref(kind, value): body = ["type": "ref", "kind": kind, "value": value]
        case let .other(kind): body = ["type": "ref", "kind": kind, "value": item.id]
        }
        if !item.body.isGroup, let room = item.room { extra["room"] = room }
        if let label = item.label { extra["label"] = label }
        if item.pinnedInGroup { extra["pinned"] = true }
        if item.archived { extra["archived"] = true }
        if item.sort != .manual { extra["sort"] = item.sort.rawValue }
        var wire: [String: Any] = ["id": item.id, "section": item.section, "order": key(order), "body": body, "shows_label": item.showsLabel]
        if let parent = item.parent { wire["parent"] = parent }
        if let span = item.span { wire["span"] = span }
        if !extra.isEmpty { wire["extra"] = extra }
        return wire
    }
}
