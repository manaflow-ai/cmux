public import Foundation

/// Each window's own `sidebar.rowOrder` choice (the sidebar menu's Keep Rows in Place / Move
/// Sessions That Need You), kept across launches by the window's id. A window that never chose
/// follows the setting.
public nonisolated struct SidebarRowOrderMemory {
    static let key = "cmux.next.sidebar.rowOrder.byWindow"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The order `window` chose; nil when it never chose.
    public func order(for window: String) -> SidebarRowOrder? {
        (defaults.dictionary(forKey: Self.key)?[window] as? String).flatMap(SidebarRowOrder.init(rawValue:))
    }

    /// Saves `order` for `window`; nil forgets it.
    public func save(_ order: SidebarRowOrder?, for window: String) {
        var saved = defaults.dictionary(forKey: Self.key) ?? [:]
        saved[window] = order?.rawValue
        defaults.set(saved, forKey: Self.key)
    }

    /// `model` with `window`'s saved order, saving every later choice under that window.
    @MainActor public func restoring(_ model: SidebarModel, window: String) -> SidebarModel {
        model.rowOrder = order(for: window)
        model.onRowOrderChange = { save($0, for: window) }
        return model
    }
}
