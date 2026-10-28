public import AppKit
public import CmuxNextDesignTokens
public import CmuxNextAppearance

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
    /// The scopes running color code, innermost last, with the tokens read once at push.
    private static var stack: [(scope: ThemeScope, tokens: ThemeTokens)] = []

    static var active: ThemeTokens? { stack.last?.tokens }
    /// The active scope (nil outside one): its surfaces and its tint over art are what its
    /// surfaces' owners paint against.
    static var activeScope: ThemeScope? { stack.last?.scope }
    /// The active scope's background image (inherited from the app), or
    /// the app's outside a scope: with an image the window is see-through
    /// at any `background-opacity` (`WindowBackdrop`).
    static var activeBackdropSelection: BackdropSelection? {
        (stack.last?.scope ?? ThemeScope.app).backdropSelection
    }

    static func push(_ scope: ThemeScope) { stack.append((scope, scope.tokens)) }
    static func pop() { _ = stack.popLast() }
}

extension ThemeScope {
    /// The nearest scope (this one or an ancestor) without a chrome
    /// emphasis: panels and hover cards draw there at full strength.
    public var fullStrength: ThemeScope {
        var scope = self
        while scope.emphasis != .full, let parent = scope.parent { scope = parent }
        return scope
    }

    /// The glyph images a ``ChromeLabel`` of this scope draws through: the nearest scope's
    /// ``sharedGlyphMasks`` (nil: each label keeps its own).
    public var glyphMasks: GlyphMaskCache? { sharedGlyphMasks ?? parent?.glyphMasks }
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
        let scope = themeScope
        ThemeContext.push(scope)
        defer { ThemeContext.pop() }
        var result: T?
        effectiveAppearance.performAsCurrentDrawingAppearance { result = body() }
        // The block runs synchronously, so `result` is set; otherwise run `body` without the appearance.
        return result ?? body()
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
