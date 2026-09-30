public import AppKit

/// Which views and windows root a scope. Weak on both sides: a scope lives
/// as long as its owner (window, workspace or terminal controller) keeps it.
@MainActor
enum ThemeScopeRegistry {
    private static let views = NSMapTable<NSView, ThemeScope>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private static let windows = NSMapTable<NSWindow, ThemeScope>(keyOptions: .weakMemory, valueOptions: .weakMemory)

    static func scope(of view: NSView) -> ThemeScope? { views.object(forKey: view) }
    static func scope(of window: NSWindow) -> ThemeScope? { windows.object(forKey: window) }

    static func setScope(_ scope: ThemeScope?, of view: NSView) {
        if let scope { views.setObject(scope, forKey: view) } else { views.removeObject(forKey: view) }
    }

    static func setScope(_ scope: ThemeScope?, of window: NSWindow) {
        if let scope { windows.setObject(scope, forKey: window) } else { windows.removeObject(forKey: window) }
    }

    /// Nearest scope: the view and its ancestors, then its window, then the
    /// windows that own that window (child windows, sheets), then `app`.
    static func resolve(_ view: NSView) -> ThemeScope {
        var current: NSView? = view
        while let candidate = current {
            if let scope = views.object(forKey: candidate) { return scope }
            current = candidate.superview
        }
        return view.window.map(resolve) ?? .app
    }

    static func resolve(_ window: NSWindow) -> ThemeScope {
        var current: NSWindow? = window
        while let candidate = current {
            if let scope = windows.object(forKey: candidate) { return scope }
            current = candidate.parent ?? candidate.sheetParent
        }
        return .app
    }
}

/// The tokens `Palette` resolves against while a view (or scope) runs its
/// color code. Main thread only; off the main thread `Palette` resolves
/// against the app theme.
@MainActor
enum ThemeContext {
    private static var stack: [ThemeTokens] = []

    static var active: ThemeTokens? { stack.last }

    static func push(_ tokens: ThemeTokens) { stack.append(tokens) }
    static func pop() { stack.removeLast() }
}

extension NSView {
    /// The scope this view draws in (its own, an ancestor's, its window's,
    /// or `ThemeScope.app`).
    public var themeScope: ThemeScope { ThemeScopeRegistry.resolve(self) }

    /// This view's scope colors, for code that reads tokens directly.
    public var themeTokens: ThemeTokens { themeScope.tokens }

    /// Runs `body` with this view's scope active: `Palette` tokens return
    /// that scope's colors (plain colors, safe to hand to AppKit controls)
    /// and the drawing appearance is this view's. Every color a view applies
    /// goes through here, in a hook that runs again on a theme change
    /// (`viewDidChangeEffectiveAppearance`, `updateLayer`, `draw`,
    /// `layout`).
    public func performWithTheme<T>(_ body: () -> T) -> T {
        ThemeContext.push(themeScope.tokens)
        defer { ThemeContext.pop() }
        var result: T?
        effectiveAppearance.performAsCurrentDrawingAppearance { result = body() }
        return result!
    }
}

extension NSWindow {
    /// The scope this window draws in: the one it adopted, else its owner
    /// window's, else `ThemeScope.app`.
    public var themeScope: ThemeScope { ThemeScopeRegistry.resolve(self) }

    /// A panel shown for `view` (hover card, editor, popover window) draws in
    /// `view`'s scope, like the window under it.
    public func adoptThemeScope(of view: NSView) {
        view.themeScope.adopt(self)
    }
}
