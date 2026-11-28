import Foundation

// WorkspaceSnapshot is generated from cmux-tui/spec/sdk-schema.json (swift_app/bindings.json, family Tree).
extension WorkspaceSnapshot {
    /// The store's home workspace, which no close path closes (`home_not_closable`).
    public var isHome: Bool { kind == "home" }

    /// What a sidebar shows.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }
}
