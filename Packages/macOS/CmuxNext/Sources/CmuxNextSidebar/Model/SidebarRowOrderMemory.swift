public import CmuxNextDesign
public import Foundation

/// Each window's own `sidebar.rowOrder` choice (the sidebar menu's Keep Rows in Place / Move
/// Sessions That Need You), kept across launches by the window's id. A window that never chose
/// follows the setting. The choices are saved oldest first, at most ``limit`` of them: a closed
/// window's id is never reused, so the oldest choice goes once the list is full.
public nonisolated struct SidebarRowOrderMemory {
    static let key = "cmux.next.sidebar.rowOrder.byWindow"
    /// The most windows whose choice is kept.
    static let limit = 64
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved `[window, order]` pairs, oldest first.
    private var saved: [[String]] {
        (defaults.array(forKey: Self.key) as? [[String]] ?? []).filter { $0.count == 2 }
    }

    /// How many windows have a saved choice.
    var count: Int { saved.count }

    /// The order `window` chose; nil when it never chose.
    public func order(for window: String) -> SidebarRowOrder? {
        saved.last { $0[0] == window }.flatMap { SidebarRowOrder(rawValue: $0[1]) }
    }

    /// Saves `order` for `window` as the newest choice; nil forgets it.
    public func save(_ order: SidebarRowOrder?, for window: String) {
        var pairs = saved.filter { $0[0] != window }
        if let order { pairs.append([window, order.rawValue]) }
        defaults.set(Array(pairs.suffix(Self.limit)), forKey: Self.key)
    }

    /// `model` with `window`'s saved order, saving every later choice under that window.
    @MainActor public func restoring(_ model: SidebarModel, window: String) -> SidebarModel {
        model.onRowOrderChange = nil // a window restored again (the launch window adopting a saved id) saves under its new id only
        model.rowOrder = order(for: window)
        model.onRowOrderChange = { save($0, for: window) }
        return model
    }
}
