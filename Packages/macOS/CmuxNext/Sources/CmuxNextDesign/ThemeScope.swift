public import AppKit

/// The theme one part of the UI draws in (plans/cmux-next/data-model.md 6).
///
/// Scopes form a tree: `ThemeScope.app` follows the Ghostty config
/// (`ThemeStore.shared`); a window scope takes its room's theme; a
/// workspace scope colors one workspace's content area; a terminal scope
/// colors one terminal surface. A scope without its own theme inherits its
/// parent's colors, so the precedence is terminal, workspace, room, config
/// (`ThemeLayers`).
///
/// Views find their scope through the view tree (`NSView.themeScope`) and
/// resolve `Palette` colors inside `performWithTheme`. Nothing is looked up
/// per frame: a scope recomputes its tokens only when its theme or an
/// ancestor's changes, then repaints the views it roots (the same hook a
/// Ghostty config reload uses: `viewDidChangeEffectiveAppearance`) behind a
/// short crossfade, and calls its `ThemeResponsive` objects.
@MainActor
public final class ThemeScope {
    /// The root scope: the Ghostty config theme.
    public static let app = ThemeScope()

    public let level: ThemeLevel
    public private(set) var parent: ThemeScope?
    /// This scope's own theme; nil inherits the parent's.
    public private(set) var spec: ThemeSpec?
    public private(set) var input: ThemeInput
    public private(set) var tokens: ThemeTokens
    /// Bumps on every change of `tokens` (tests, diagnostics).
    public private(set) var generation = 0

    private var overrideInput: ThemeInput?
    private let children = NSHashTable<ThemeScope>.weakObjects()
    private let roots = NSHashTable<NSView>.weakObjects()
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private let responders = NSHashTable<AnyObject>.weakObjects()

    private init() {
        level = .config
        input = ThemeStore.shared.input
        tokens = ThemeStore.shared.tokens
    }

    /// A scope at `level` that inherits `parent` until it gets its own theme.
    public init(level: ThemeLevel, parent: ThemeScope = .app) {
        self.level = level == .config ? .room : level
        self.parent = parent
        input = parent.input
        tokens = parent.tokens
        parent.children.add(self)
    }

    /// The spec in effect here: this scope's, else the nearest ancestor's.
    /// Nil means the Ghostty config.
    public var effectiveSpec: ThemeSpec? { spec ?? parent?.effectiveSpec }

    /// The level whose theme colors this scope (`.config` when none is set).
    public var source: ThemeLevel {
        if spec != nil { return level }
        return parent?.source ?? .config
    }

    /// The light or dark system appearance matching this scope's colors,
    /// for windows, panels and AppKit controls.
    public var appearance: NSAppearance {
        NSAppearance(named: tokens.isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    // MARK: Changes

    /// Sets this scope's own theme. `input` is the spec's resolved colors;
    /// a nil spec (or nil input) clears it and inherits again. Repaints
    /// what this scope roots, with a crossfade when `animated`.
    public func setOverride(_ spec: ThemeSpec?, input: ThemeInput?, animated: Bool = true) {
        let resolved = spec == nil ? nil : input
        self.spec = resolved == nil ? nil : spec
        guard resolved != overrideInput else { return }
        overrideInput = resolved
        update(animated: animated, repaint: true)
    }

    /// Moves this scope under another parent (a workspace shown in another
    /// window, a terminal moved to another workspace).
    public func setParent(_ newParent: ThemeScope, animated: Bool = false) {
        guard newParent !== parent, newParent !== self else { return }
        parent?.children.remove(self)
        parent = newParent
        newParent.children.add(self)
        for view in roots.allObjects { applyAppearance(to: view) }
        update(animated: animated, repaint: true)
    }

    /// Called by `ThemeStore.shared` after a Ghostty config change. The
    /// store repaints every window itself, so scopes only recompute.
    func storeDidChange() {
        update(animated: false, repaint: false)
    }

    private func update(animated: Bool, repaint: Bool) {
        let next = level == .config ? ThemeStore.shared.input : overrideInput ?? parent?.input ?? ThemeStore.shared.input
        // The parent's light/dark may have flipped even when these colors
        // did not (an overridden workspace in a room that changed).
        defer { for view in roots.allObjects { applyAppearance(to: view) } }
        guard next != input else { return }
        input = next
        let derived = level == .config ? ThemeStore.shared.tokens : ThemeTokens.derive(from: next)
        let changed = derived != tokens
        tokens = derived
        if changed { generation += 1 }
        for child in children.allObjects { child.update(animated: animated, repaint: false) }
        guard changed else { return }
        if repaint { self.repaint(animated: animated) }
        for responder in responders.allObjects {
            (responder as? any ThemeResponsive)?.themeDidChange()
        }
    }

    // MARK: Views and windows

    /// Makes `view` and its subtree draw in this scope and repaints it.
    public func root(_ view: NSView) {
        if let previous = ThemeScopeRegistry.scope(of: view), previous !== self { previous.roots.remove(view) }
        ThemeScopeRegistry.setScope(self, of: view)
        roots.add(view)
        applyAppearance(to: view)
        Self.invalidate(view)
    }

    /// Returns `view` to whatever scope its ancestors draw in.
    public func unroot(_ view: NSView) {
        guard ThemeScopeRegistry.scope(of: view) === self else { return }
        ThemeScopeRegistry.setScope(nil, of: view)
        roots.remove(view)
        view.appearance = nil
        Self.invalidate(view)
    }

    /// Makes `window` (a main window or a panel it owns) draw in this scope:
    /// its appearance, and every view in it that roots no other scope.
    public func adopt(_ window: NSWindow) {
        if let previous = ThemeScopeRegistry.scope(of: window), previous !== self { previous.windows.remove(window) }
        ThemeScopeRegistry.setScope(self, of: window)
        windows.add(window)
        window.appearance = appearance
        if let content = window.contentView { Self.invalidate(content) }
    }

    /// Calls `responder.themeDidChange()` after every change of this scope's
    /// colors while it lives.
    public func addResponder(_ responder: any ThemeResponsive) {
        responders.add(responder)
    }

    /// Runs `body` with this scope's colors active for `Palette` and its
    /// appearance as the drawing appearance (layer owners without a view).
    public func perform<T>(_ body: () -> T) -> T {
        ThemeContext.push(tokens)
        defer { ThemeContext.pop() }
        var result: T?
        appearance.performAsCurrentDrawingAppearance { result = body() }
        return result!
    }

    /// A root view takes an explicit appearance only where its scope's
    /// light/dark differs from what it inherits, so AppKit controls inside a
    /// light workspace in a dark room draw light.
    private func applyAppearance(to view: NSView) {
        let inherited = parent?.tokens.isDark ?? tokens.isDark
        view.appearance = inherited == tokens.isDark ? nil : appearance
    }

    private func repaint(animated: Bool) {
        let fade = animated && Motion.animatesFades
        for view in roots.allObjects {
            if fade { Self.crossfade(view.layer) }
            Self.invalidate(view)
        }
        for window in windows.allObjects {
            window.appearance = appearance
            guard let content = window.contentView else { continue }
            if fade { Self.crossfade(content.layer) }
            Self.invalidate(content)
            window.invalidateShadow()
        }
    }

    /// A theme switch crossfades in place: no layout change, no restart.
    private static func crossfade(_ layer: CALayer?) {
        guard let layer else { return }
        let transition = Motion.crossfadeAction
        transition.duration = Motion.duration(.theme)
        transition.timingFunction = Motion.fadeCurve
        layer.add(transition, forKey: "cmux.themeCrossfade")
    }

    /// Every view re-resolves its colors when its effective appearance
    /// changes; a theme change is that, even dark to dark, where AppKit
    /// would not call the hook itself.
    static func invalidate(_ view: NSView) {
        view.needsDisplay = true
        view.needsLayout = true
        view.viewDidChangeEffectiveAppearance()
        for subview in view.subviews { invalidate(subview) }
    }
}
