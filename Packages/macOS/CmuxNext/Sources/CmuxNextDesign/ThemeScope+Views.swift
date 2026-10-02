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

    /// When this view roots a scope (a workspace's content, a terminal
    /// surface), makes the scope inherit from wherever the view now sits.
    /// Call after installing the view.
    public func reparentRootedThemeScope() {
        guard let scope = ThemeScopeRegistry.scope(of: self), let superview else { return }
        scope.setParent(superview.themeScope)
    }

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
    /// A panel always draws at full strength: it adopts the nearest scope
    /// without a chrome emphasis (an unfocused pane's subtle strip scope
    /// gives way to its pane's).
    public func adoptThemeScope(of view: NSView) {
        view.themeScope.fullStrength.adopt(self)
    }
}

/// A plain container that runs `onThemeChange` whenever its colors must be
/// re-resolved (moved into a window, appearance change, theme scope
/// repaint), for panels built from stock AppKit controls.
public final class ThemeChangeView: NSView {
    public var onThemeChange: (() -> Void)?

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onThemeChange?()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onThemeChange?()
    }
}
