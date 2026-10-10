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

    /// Art is inherited independently of color themes, so every window
    /// follows the app's one selection even with room or terminal themes.
    public var backdropSelection: BackdropSelection? { selectedBackdropSelection ?? parent?.backdropSelection }
    public var backdropArt: BackdropArt? {
        if case .art(let art) = backdropSelection { return art }
        return nil
    }
    public var appearanceTuning: AppearanceTuning { selectedAppearanceTuning ?? parent?.appearanceTuning ?? .identity }
    private var selectedBackdropSelection: BackdropSelection?
    private var selectedAppearanceTuning: AppearanceTuning?
    /// The user's per-surface backgrounds (`appearance.surfaces`), inherited
    /// like art: one app-wide setting, read by every surface's owner through
    /// `Palette.fill(for:)`.
    public var surfaceBackgrounds: SurfaceBackgrounds { selectedSurfaceBackgrounds ?? parent?.surfaceBackgrounds ?? .none }
    private var selectedSurfaceBackgrounds: SurfaceBackgrounds?

    /// Changes the per-surface backgrounds and repaints this scope and its
    /// descendants (every owner re-reads its fill in its theme hook).
    public func setSurfaceBackgrounds(_ backgrounds: SurfaceBackgrounds) {
        guard selectedSurfaceBackgrounds != backgrounds else { return }
        selectedSurfaceBackgrounds = backgrounds
        repaintBackdropArt()
    }

    /// Changes art and repaints this scope and its descendants without a
    /// Ghostty reload or changing any terminal colors.
    /// - Parameter art: The painting to show; nil restores inherited art.
    public func setBackdropArt(_ art: BackdropArt?) {
        setBackdropSelection(art.map(BackdropSelection.art))
    }

    /// Changes the selected bundled or system image and repaints descendants.
    public func setBackdropSelection(_ selection: BackdropSelection?) {
        guard selectedBackdropSelection != selection else { return }
        selectedBackdropSelection = selection
        repaintBackdropArt()
    }

    /// Changes live tuning without changing theme colors or persisted settings.
    public func setAppearanceTuning(_ tuning: AppearanceTuning) {
        let clamped = AppearanceTuning(glassTransparency: tuning.glassTransparency,
                                       hue: tuning.hue,
                                       saturation: tuning.saturation)
        guard selectedAppearanceTuning != clamped else { return }
        selectedAppearanceTuning = clamped
        repaintBackdropArt()
    }

    private func repaintBackdropArt() {
        repaint(animated: false)
        for responder in responders.allObjects {
            (responder as? any ThemeResponsive)?.themeDidChange()
        }
        for child in children.allObjects { child.repaintBackdropArt() }
    }

    public let level: ThemeLevel
    public private(set) var parent: ThemeScope?
    /// This scope's own theme; nil inherits the parent's.
    public private(set) var spec: ThemeSpec?
    public private(set) var input: ThemeInput
    /// This scope's own colors (its theme, else its parent's). Children
    /// inherit these.
    public private(set) var ownTokens: ThemeTokens
    /// The colors the views and windows this scope roots draw in: those of
    /// the scope it shows (`show(_:)`) when they are as light or dark as its
    /// own, else its own. A light workspace in a dark room never turns the
    /// window's chrome light.
    public var tokens: ThemeTokens {
        guard let shown else { return ownTokens.emphasized(emphasis) }
        let candidate = shown.tokens
        return (candidate.isDark == ownTokens.isDark ? candidate : ownTokens).emphasized(emphasis)
    }
    /// How strongly this scope's own views draw (a pane's tab strip in an
    /// unfocused pane: `ChromeEmphasis`). Children keep the plain colors.
    public private(set) var emphasis: ChromeEmphasis = .full
    /// Bumps on every change of `tokens` (tests, diagnostics).
    public private(set) var generation = 0
    /// The scope whose colors this scope's own views draw in: a window's
    /// room scope shows its current workspace's, so the sidebar and
    /// titlebar always match the content beside them.
    public private(set) weak var shown: ThemeScope?
    private let viewers = NSHashTable<ThemeScope>.weakObjects()
    /// `tokens` as last painted, so a change is noticed whichever way it came.
    private var displayed: ThemeTokens

    private var overrideInput: ThemeInput?
    private let children = NSHashTable<ThemeScope>.weakObjects()
    private let roots = NSHashTable<NSView>.weakObjects()
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private let responders = NSHashTable<AnyObject>.weakObjects()

    private init() {
        level = .config
        input = ThemeStore.shared.input
        ownTokens = ThemeStore.shared.tokens
        displayed = ownTokens
    }

    /// A scope at `level` that inherits `parent` until it gets its own theme.
    public init(level: ThemeLevel, parent: ThemeScope = .app) {
        self.level = level == .config ? .room : level
        self.parent = parent
        input = parent.input
        ownTokens = parent.ownTokens
        displayed = ownTokens
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

    /// The nearest scope (this one or an ancestor) without a chrome
    /// emphasis: panels and hover cards draw there at full strength.
    public var fullStrength: ThemeScope {
        var scope = self
        while scope.emphasis != .full, let parent = scope.parent { scope = parent }
        return scope
    }

    /// Sets `emphasis` and repaints what this scope roots when it changed.
    public func setEmphasis(_ emphasis: ChromeEmphasis, animated: Bool = true) {
        guard emphasis != self.emphasis else { return }
        self.emphasis = emphasis
        refreshDisplay(animated: animated, repaint: true)
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

    /// Draws this scope's own views and windows in `scope`'s colors (nil:
    /// its own). Children keep inheriting this scope's own theme, so a
    /// parked workspace never takes the shown one's colors.
    public func show(_ scope: ThemeScope?, animated: Bool = false) {
        guard scope !== shown else { return }
        // A chain that leads back here would never resolve its colors.
        var next = scope
        while let candidate = next {
            if candidate === self { return }
            next = candidate.shown
        }
        shown?.viewers.remove(self)
        shown = scope
        scope?.viewers.add(self)
        refreshDisplay(animated: animated, repaint: true)
    }

    /// Repaints and notifies when `tokens` moved away from what was last
    /// painted: this scope's own colors, the shown scope's, or which of the
    /// two applies changed.
    private func refreshDisplay(animated: Bool, repaint: Bool) {
        // A child root's explicit appearance compares with these colors.
        for child in children.allObjects { for view in child.roots.allObjects { child.applyAppearance(to: view) } }
        let now = tokens
        guard now != displayed else { return }
        displayed = now
        generation += 1
        if repaint { self.repaint(animated: animated) }
        for responder in responders.allObjects {
            (responder as? any ThemeResponsive)?.themeDidChange()
        }
        for viewer in viewers.allObjects where viewer.shown === self {
            viewer.refreshDisplay(animated: animated, repaint: true)
        }
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
        ownTokens = derived
        for child in children.allObjects { child.update(animated: animated, repaint: false) }
        refreshDisplay(animated: animated, repaint: repaint)
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
