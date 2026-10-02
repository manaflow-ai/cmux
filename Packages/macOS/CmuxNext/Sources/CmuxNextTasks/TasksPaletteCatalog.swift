import Foundation

/// Palette entries for Tasks, generated from the operation catalog export
/// (`cmux task catalog`, checked in as Resources/tasks-catalog.json; a Rust
/// test fails when the copy is stale). The App registers these as palette
/// actions; nothing here hand-lists ops.
public nonisolated struct TasksPaletteItem: Sendable, Hashable, Identifiable {
    /// The catalog op, e.g. `task.create`.
    public let op: String
    /// Localized palette title.
    public let title: String
    public let cliPath: String
    public var id: String { op }
}

public nonisolated enum TasksPaletteCatalog {
    private struct Export: Decodable {
        struct Operation: Decodable {
            struct Palette: Decodable { var title: String }
            struct CLI: Decodable { var path: String }
            var name: String
            var palette: Palette?
            var cli: CLI
        }
        var operations: [Operation]
    }

    /// Every op that declares a palette surface, in catalog order.
    public static func items() -> [TasksPaletteItem] {
        guard let url = Bundle.module.url(forResource: "tasks-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let export = try? JSONDecoder().decode(Export.self, from: data)
        else { return [] }
        return export.operations.compactMap { op in
            op.palette.map { TasksPaletteItem(op: op.name, title: TasksStrings.palette(op: op.name, fallback: $0.title), cliPath: op.cli.path) }
        }
    }
}
