import Foundation

/// A single column on the kanban board (`kanban.columns` in `cmux.json`).
///
/// Columns are global config, shared across every window — see
/// `KanbanCatalogSection`. A workspace's membership in a column is separate,
/// per-tab state (`Workspace.kanbanColumnId`), so deleting a column here never
/// touches the workspace itself, only its assignment.
public struct KanbanColumn: Codable, Identifiable, Equatable, Sendable {
    /// Stable, non-localized identifier. Persisted in `Workspace.kanbanColumnId`
    /// and used as the JSON object key, so renaming ``title`` never breaks
    /// existing card assignments.
    public let id: String
    public var title: String
    /// Sort position among columns; lower sorts first.
    public var order: Int
    /// Optional hex color for the column header, e.g. "#C0392B".
    public var colorHex: String?
    /// The pinned Archive column. Non-deletable but renamable/recolorable.
    public var isArchive: Bool
    /// Collapsed columns hide their cards, showing only the header.
    public var isCollapsed: Bool

    public init(
        id: String,
        title: String,
        order: Int,
        colorHex: String? = nil,
        isArchive: Bool = false,
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.colorHex = colorHex
        self.isArchive = isArchive
        self.isCollapsed = isCollapsed
    }

    /// Seeded columns for a fresh install: three working buckets plus a
    /// collapsed Archive. Titles are placeholder English; localization of the
    /// display title happens in a later stage, so the stable `id` is what
    /// persisted card assignments key off of.
    public static let defaults: [KanbanColumn] = [
        KanbanColumn(id: "todo", title: "To Do", order: 0),
        KanbanColumn(id: "in-progress", title: "In Progress", order: 1),
        KanbanColumn(id: "done", title: "Done", order: 2),
        KanbanColumn(id: "archive", title: "Archive", order: 3, isArchive: true, isCollapsed: true),
    ]
}

// MARK: - SettingCodable

/// Stored as a nested JSON object array, mirroring `TerminalUploadCommandRule`.
/// Decode is all-or-nothing per column, and `Array`'s conformance makes a
/// malformed list reject as a whole (falling back to ``defaults``), so a
/// corrupt entry never silently drops just one column.
extension KanbanColumn: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> KanbanColumn? {
        decodeFromJSON(raw)
    }

    public func encodeForUserDefaults() -> Any {
        encodeForJSON()
    }

    public static func decodeFromJSON(_ raw: Any?) -> KanbanColumn? {
        guard let object = raw as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(KanbanColumn.self, from: data)
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return object
    }
}
