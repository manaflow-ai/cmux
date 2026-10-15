public import Foundation

/// Remembers the last DevTools dock side and sizes, so the next DevTools opens where the user
/// left the previous one (as Chrome does).
///
/// Backed by an injected `UserDefaults` suite; invalid stored values fall back to the defaults.
///
/// ```swift
/// let store = BrowserDevToolsLayoutStore(defaults: .standard)  // composition root only
/// var layout = store.load()
/// layout.dock = .right
/// store.save(layout)
/// ```
@MainActor
public final class BrowserDevToolsLayoutStore {
    /// The defaults key holding the remembered layout dictionary.
    public static let defaultsKey = "browser.devTools.layout"

    private let defaults: UserDefaults

    /// Creates a store over a defaults suite.
    /// - Parameter defaults: The suite that keeps the layout.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The remembered layout, or the default layout when nothing valid is stored.
    /// - Returns: The layout the next DevTools starts with.
    public func load() -> BrowserDevToolsLayout {
        var layout = BrowserDevToolsLayout()
        guard let stored = defaults.dictionary(forKey: Self.defaultsKey) else { return layout }
        if let dock = (stored["dock"] as? String).flatMap(BrowserDevToolsDock.init(rawValue:)) { layout.dock = dock }
        if let bottom = stored["bottom"] as? Double, BrowserDevToolsLayout.validFractions.contains(bottom) {
            layout.bottomFraction = bottom
        }
        if let side = stored["side"] as? Double, BrowserDevToolsLayout.validFractions.contains(side) {
            layout.sideFraction = side
        }
        return layout
    }

    /// Remembers `layout` for the next DevTools.
    /// - Parameter layout: The layout to keep.
    public func save(_ layout: BrowserDevToolsLayout) {
        defaults.set([
            "dock": layout.dock.rawValue,
            "bottom": layout.bottomFraction,
            "side": layout.sideFraction,
        ], forKey: Self.defaultsKey)
    }
}
