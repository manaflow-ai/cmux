import Foundation

/// Settings under the dotted-id prefix `kanban.*`.
public struct KanbanCatalogSection: SettingCatalogSection {
    public let columns = JSONKey<[KanbanColumn]>(
        id: "kanban.columns",
        defaultValue: KanbanColumn.defaults
    )

    public init() {}
}
