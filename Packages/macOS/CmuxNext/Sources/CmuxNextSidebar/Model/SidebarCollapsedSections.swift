public import Foundation

/// The layout sections this Mac keeps collapsed (Chats and the other app
/// and item sections), read at window open and saved on every toggle, so a
/// relaunch keeps them (Leo 2026-10-06). Workspace sections keep theirs in
/// the sidebar snapshot.
public struct SidebarCollapsedSections {
    public static let key = "cmux.next.sidebar.collapsedSections"
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> Set<LayoutSectionID> {
        Set((defaults.stringArray(forKey: Self.key) ?? []).map(LayoutSectionID.init))
    }

    public func save(_ ids: Set<LayoutSectionID>) {
        defaults.set(ids.map(\.rawValue).sorted(), forKey: Self.key)
    }

    /// `model` with the saved sections collapsed, saving every later toggle.
    @MainActor public func restoring(_ model: SidebarModel) -> SidebarModel {
        model.collapsedLayoutSections = load()
        model.onCollapsedLayoutSectionsChange = { save($0) }
        return model
    }
}
