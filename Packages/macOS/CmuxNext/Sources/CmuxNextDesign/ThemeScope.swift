public import AppKit
public import CmuxNextDesignTokens

/// The theme one part of the UI draws in (plans/cmux-next/data-model.md 6).
///
/// Scopes form a tree: `ThemeScope.app` follows the Ghostty config
/// (its ``store``, which every scope of the tree shares); a window scope takes its room's theme; a
/// workspace scope colors one workspace's content area; a terminal scope
/// colors one terminal surface. A scope without its own theme inherits its
/// parent's colors, so the precedence is terminal, workspace, room, config
/// (`ThemeLayers`).
///
/// Views find their scope through the view tree (`NSView.themeScope`) and
/// resolve `Palette` colors inside `performWithTheme`. Nothing is looked up
/// per frame: a scope recomputes its tokens only when its theme or an
/// ancestor's changes, then runs the theme hook (`viewDidChangeEffectiveAppearance`,
/// the one a Ghostty config reload uses) of the views it draws, once each and
/// never inside another scope's region, with their layer colors blending on the
/// render server (`ThemeRepaint`), and calls its `ThemeResponsive` objects.
@MainActor
public final class ThemeScope {
    /// The root scope: the Ghostty config theme.
    ///
    /// The one ambient theme root: `Palette` and the other static design lookups fall back to it
    /// outside ``performWithTheme`` (like `NSAppearance.current`), so it cannot be passed to them.
    /// It makes the app's ``ThemeStore``; the composition root reads it once and hands that store to
    /// the App's owners (`AppServices.themeStore`).
    public static let app = ThemeScope(root: ThemeStore(publishesGlobally: true))  // singleton-allow: the ambient theme root static Palette lookups fall back to

    /// The store this scope's tree derives from: the root's, inherited by every child.
    public let store: ThemeStore

    /// Art is inherited independently of color themes, so every window
    /// follows the app's one selection even with room or terminal themes.
    /// A room shows the background its shown workspace pinned (cx-t2x.5),
    /// so a top page (`show(nil)`) is back on the app's.
    public var backdropSelection: BackdropSelection? {
        if hidesBackdrops { return nil }
        if let shown, shown.pinsBackdrop { return shown.backdropSelection }
        return pinsNoBackdrop ? nil : selectedBackdropSelection ?? parent?.backdropSelection
    }
    /// The glass tint over art: the one a workspace chose (``pinBackdropTint(_:)``; a room reads
    /// its shown workspace's), else the window Opacity the user set (``setWindowBackdropTint(_:)``,
    /// inherited from the app); nil keeps the work's own tint. The legibility floor still applies
    /// on top.
    public var backdropTintOpacity: Double? { shown?.pinnedTint ?? pinnedTint ?? inheritedWindowTint }
    private var pinnedTint: Double?
    /// `appearance.backgroundOpacity` as a tint over art, set on the app's scope.
    private var windowTint: Double?
    private var inheritedWindowTint: Double? { windowTint ?? parent?.inheritedWindowTint }
    /// Whether ``pinBackdrop(_:)`` gave this scope a background of its own.
    private var pinsBackdrop: Bool { pinsNoBackdrop || isPinned }
    /// `ui.reducedBackgrounds`: no picture here or in any descendant, whatever they picked
    /// (``setBackdropsHidden(_:)``); their picks stay and draw again when it is off.
    private var hidesBackdrops: Bool { backdropsHidden || parent?.hidesBackdrops == true }
    private var backdropsHidden = false
    private var isPinned = false
    public var backdropArt: BackdropArt? {
        if case .art(let art) = backdropSelection { return art }
        return nil
    }
    public var appearanceTuning: AppearanceTuning { selectedAppearanceTuning ?? parent?.appearanceTuning ?? .identity }
    private var selectedBackdropSelection: BackdropSelection?
    /// Plain glass here even when an ancestor has art (``pinBackdrop(_:)``).
    private var pinsNoBackdrop = false
    private var selectedAppearanceTuning: AppearanceTuning?
    /// The user's per-surface backgrounds (`appearance.surfaces`), inherited
    /// like art: one app-wide setting, read by every surface's owner through
    /// `Palette.fill(for:)`.
    public var surfaceBackgrounds: SurfaceBackgrounds { selectedSurfaceBackgrounds ?? parent?.surfaceBackgrounds ?? .none }
    private var selectedSurfaceBackgrounds: SurfaceBackgrounds?

    /// Changes the per-surface backgrounds and repaints this scope and its
    /// descendants (every owner re-reads its fill in its theme hook).
    public func setSurfaceBackgrounds(_ backgrounds: SurfaceBackgrounds) {
        ThemeRepaint.batch {
            guard selectedSurfaceBackgrounds != backgrounds else { return }
            selectedSurfaceBackgrounds = backgrounds
            repaintBackdropArt()
        }
    }

    /// Changes the selected bundled or system image and repaints descendants.
    public func setBackdropSelection(_ selection: BackdropSelection?) {
        ThemeRepaint.batch {
            guard selectedBackdropSelection != selection else { return }
            selectedBackdropSelection = selection
            // Settings pick the art before the first window: start decoding it now, so that window
            // finds it ready.
            BackdropImageStore.shared.prewarm(selection)
            repaintBackdropArt()
        }
    }

    /// Hides every picture of this scope and its descendants (`ui.reducedBackgrounds`), so their
    /// windows draw the plain theme background; their own picks are kept for when it is off.
    public func setBackdropsHidden(_ hidden: Bool) {
        ThemeRepaint.batch {
            guard backdropsHidden != hidden else { return }
            backdropsHidden = hidden
            repaintBackdropArt()
            for viewer in viewers.allObjects { viewer.repaintBackdropArt() }
        }
    }

    /// Gives this scope its own background over its ancestors' (a workspace's own pick, cx-t2x.5):
    /// `.none` is plain glass even under art, `.inherit` follows the ancestors again.
    public func pinBackdrop(_ pin: BackdropPin) {
        ThemeRepaint.batch {
            let (selection, none): (BackdropSelection?, Bool) = switch pin {
            case .inherit: (nil, false)
            case .none: (nil, true)
            case .selection(let selection): (selection, false)
            }
            guard selectedBackdropSelection != selection || pinsNoBackdrop != none else { return }
            selectedBackdropSelection = selection
            pinsNoBackdrop = none
            isPinned = selection != nil
            BackdropImageStore.shared.prewarm(selection)
            repaintBackdropArt()
            // The rooms showing this scope draw its background.
            for viewer in viewers.allObjects { viewer.repaintBackdropArt() }
        }
    }

    /// Gives this scope its own glass tint over art (a workspace's Opacity, cx-t2x.5), 0...1; at
    /// 1 the window is opaque and hides the art. nil follows the work's own tint.
    public func pinBackdropTint(_ tint: Double?) {
        ThemeRepaint.batch {
            // A non-finite tint (a hand-edited "nan") follows the work's.
            let tint = tint.flatMap { $0.isFinite ? min(max($0, 0), WindowBackdrop.maximumWorkspaceTint) : nil }
            guard pinnedTint != tint else { return }
            pinnedTint = tint
            repaintBackdropArt()
            for viewer in viewers.allObjects { viewer.repaintBackdropArt() }
        }
    }

    /// The window Opacity the user set (`appearance.backgroundOpacity`), as the tint over art for
    /// this scope and every descendant without a workspace tint of its own: 0...1 like a
    /// workspace's, so 100% covers the picture fully and the slider moves the window one way
    /// only (it fell back to the work's lighter tint at 100%). nil (unset) keeps the work's tint.
    public func setWindowBackdropTint(_ tint: Double?) {
        ThemeRepaint.batch {
            let tint = tint.flatMap { $0.isFinite ? min(max($0, 0), WindowBackdrop.maximumWorkspaceTint) : nil }
            guard windowTint != tint else { return }
            windowTint = tint
            repaintBackdropArt()
        }
    }

    /// Changes live tuning without changing theme colors or persisted settings.
    public func setAppearanceTuning(_ tuning: AppearanceTuning) {
        ThemeRepaint.batch {
            let clamped = AppearanceTuning(glassTransparency: tuning.glassTransparency,
                                           hue: tuning.hue,
                                           saturation: tuning.saturation)
            guard selectedAppearanceTuning != clamped else { return }
            selectedAppearanceTuning = clamped
            repaintBackdropArt()
        }
    }

    /// The theme's own accent (`ThemeInput.accentColor`) this scope inherits, apart from Art Color.
    private var themeAccentColor: ThemeRGB? {
        if level == .config { return store.input.accentColor }
        if let overrideInput { return overrideInput.accentColor }
        guard let parent else { return store.input.accentColor }
        return parent.themeAccentColor
    }

    /// What a scope's background draws besides its tokens (art, glass tint, surfaces, tuning),
    /// as last painted: a child repaints for its parent's change only when what it inherits moved.
    private struct BackdropKey: Equatable {
        var selection: BackdropSelection?
        var tint: Double?
        var surfaces: SurfaceBackgrounds
        var tuning: AppearanceTuning
    }
    private var displayedBackdrop: BackdropKey?

    /// Repaints this scope's views for a background change, then each child whose inherited
    /// background changed with it (a child with its own pick keeps its views as they are).
    private func repaintBackdropArt(force: Bool = true) {
        let key = BackdropKey(selection: backdropSelection, tint: backdropTintOpacity,
                              surfaces: surfaceBackgrounds, tuning: appearanceTuning)
        guard force || key != displayedBackdrop else { return }
        let previous = displayedBackdrop
        displayedBackdrop = key
        // The shown opacity follows the picture and its tuning; a tint drag re-reads nothing.
        if previous?.selection != key.selection || previous?.tuning != key.tuning { store.backdropRevision.bump() }
        // Art Color: another work is another accent.
        if store.accentFollowsArt { update(animated: false, repaint: false) }
        repaint(animated: false, from: nil)
        // After the batch's hooks: the responders see the new appearances, and their colors blend.
        ThemeRepaint.afterHooks { [weak self] in
            for responder in self?.responders.allObjects ?? [] {
                (responder as? any ThemeResponsive)?.themeDidChange()
            }
        }
        for child in children.allObjects { child.repaintBackdropArt(force: false) }
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
    /// the scope it shows (`show(_:)`), else its own. At any brightness: a
    /// light workspace in a dark room turns the window's chrome light, with
    /// the color transition (Lawrence 2026-10-15, cx-3rf4z; this replaces the
    /// earlier rule that kept the room's light/dark).
    public var tokens: ThemeTokens {
        (shown?.tokens ?? ownTokens).emphasized(emphasis)
    }
    /// How strongly this scope's own views draw (a pane's tab strip in an
    /// unfocused pane: `ChromeEmphasis`). Children keep the plain colors.
    public private(set) var emphasis: ChromeEmphasis = .full
    /// Bumps on every change of `tokens` (tests, diagnostics).
    public private(set) var generation = 0
    /// Bumps on every repaint of this scope's views (tokens or background): a hidden subtree the
    /// repaint left out repaints when shown (`ThemeRepaint`).
    private(set) var paintRevision = 0
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

    // cx-qxxu: released with its terminal, which Cmd-T's New Tab page can withdraw while its
    // action runs; a main-actor deinit's hop traps there (cx-t7hu).
    nonisolated deinit {}

    private init(root store: ThemeStore) {
        level = .config
        self.store = store
        input = store.input
        ownTokens = store.tokens
        displayed = ownTokens
        store.root = self
    }

    /// A scope at `level` that inherits `parent` until it gets its own theme.
    public init(level: ThemeLevel, parent: ThemeScope = .app) {
        self.level = level == .config ? .room : level
        self.parent = parent
        store = parent.store
        input = parent.input
        ownTokens = parent.ownTokens
        displayed = ownTokens
        parent.children.add(self)
        // Art Color: the parent's input carries its own art's hue, not this scope's.
        if store.accentFollowsArt { update(animated: false, repaint: false) }
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
    /// what this scope draws, its colors blending when `animated`.
    public func setOverride(_ spec: ThemeSpec?, input: ThemeInput?, animated: Bool = true) {
        ThemeRepaint.batch {
            let resolved = spec == nil ? nil : input
            self.spec = resolved == nil ? nil : spec
            guard resolved != overrideInput else { return }
            overrideInput = resolved
            update(animated: animated, repaint: true)
        }
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
        ThemeRepaint.batch {
            guard emphasis != self.emphasis else { return }
            self.emphasis = emphasis
            refreshDisplay(animated: animated, repaint: true)
        }
    }

    /// Moves this scope under another parent (a workspace shown in another
    /// window, a terminal moved to another workspace).
    public func setParent(_ newParent: ThemeScope, animated: Bool = false) {
        ThemeRepaint.batch {
            guard newParent !== parent, newParent !== self else { return }
            parent?.children.remove(self)
            parent = newParent
            newParent.children.add(self)
            ThemeRepaint.beforeHooks { [weak self] in
                guard let self else { return }
                for view in self.roots.allObjects { self.applyAppearance(to: view) }
            }
            update(animated: animated, repaint: true)
        }
    }

    /// Draws this scope's own views and windows in `scope`'s colors (nil:
    /// its own). Children keep inheriting this scope's own theme, so a
    /// parked workspace never takes the shown one's colors.
    public func show(_ scope: ThemeScope?, animated: Bool = false) {
        ThemeRepaint.batch {
            guard scope !== shown else { return }
            // A chain that leads back here would never resolve its colors.
            var next = scope
            while let candidate = next {
                if candidate === self { return }
                next = candidate.shown
            }
            let backdrop = (backdropSelection, backdropTintOpacity)
            shown?.viewers.remove(self)
            shown = scope
            scope?.viewers.add(self)
            refreshDisplay(animated: animated, repaint: true)
            if backdropSelection != backdrop.0 || backdropTintOpacity != backdrop.1 { repaintBackdropArt() }
        }
    }

    /// Repaints and notifies when `tokens` moved away from what was last
    /// painted: this scope's own colors, the shown scope's, or which of the
    /// two applies changed.
    private func refreshDisplay(animated: Bool, repaint: Bool) {
        let now = tokens, previous = displayed
        // The windows take the new light/dark before any hook of the batch runs (and after it
        // recorded the colors on screen): a child root that compares with it then never inherits
        // the old one for a moment (now that the room follows a workspace of any light/dark).
        if repaint, now != previous {
            ThemeRepaint.beforeHooks { [weak self] in
                guard let self else { return }
                for window in self.windows.allObjects where window.appearance?.name != self.appearance.name { window.appearance = self.appearance }
            }
        }
        // A child root's explicit appearance compares with this scope's light/dark: only a flip
        // can change it.
        if now.isDark != previous.isDark {
            ThemeRepaint.beforeHooks { [weak self] in
                guard let self else { return }
                for child in self.children.allObjects { for view in child.roots.allObjects { child.applyAppearance(to: view) } }
            }
        }
        guard now != previous else { return }
        displayed = now
        generation += 1
        if repaint { self.repaint(animated: animated, from: previous) }
        // After the batch's hooks: the responders see the new appearances, and their colors blend.
        ThemeRepaint.afterHooks { [weak self] in
            for responder in self?.responders.allObjects ?? [] {
                (responder as? any ThemeResponsive)?.themeDidChange()
            }
        }
        for viewer in viewers.allObjects where viewer.shown === self {
            viewer.refreshDisplay(animated: animated, repaint: true)
        }
    }

    /// Called by the tree's ``store`` after a Ghostty config change. The
    /// store repaints every window itself, so scopes only recompute.
    func storeDidChange() {
        ThemeRepaint.batch {
            update(animated: false, repaint: false)
        }
    }

    /// Art Color turned on or off: the config's own colors did not change, so every scope below
    /// re-derives its accent itself.
    func accentSourceDidChange() {
        ThemeRepaint.batch {
            update(animated: false, repaint: false)
            for child in children.allObjects { child.accentSourceDidChange() }
        }
    }

    private func update(animated: Bool, repaint: Bool) {
        var next = level == .config ? store.input : overrideInput ?? parent?.input ?? store.input
        next.accent = store.accent
        // Art Color: the hue of the art this scope shows, else the theme's own accent.
        if store.accentFollowsArt, level != .config {
            next.accentColor = backdropArt?.accentHue ?? themeAccentColor
        }
        // The parent's light/dark may have flipped even when these colors
        // did not (an overridden workspace in a room that changed).
        defer {
            ThemeRepaint.beforeHooks { [weak self] in
                guard let self else { return }
                for view in self.roots.allObjects { self.applyAppearance(to: view) }
            }
        }
        guard next != input else { return }
        input = next
        let derived = level == .config ? store.tokens : ThemeTokens.derive(from: next)
        ownTokens = derived
        // Each child that inherits these colors repaints its own views (this scope's pass stops
        // at their roots).
        for child in children.allObjects { child.update(animated: animated, repaint: repaint) }
        refreshDisplay(animated: animated, repaint: repaint)
    }

    // MARK: Views and windows

    /// Makes `view` and its subtree draw in this scope and repaints it.
    public func root(_ view: NSView) {
        ThemeRepaint.batch {
            if let previous = ThemeScopeRegistry.scope(of: view), previous !== self { previous.roots.remove(view) }
            ThemeScopeRegistry.setScope(self, of: view)
            roots.add(view)
            applyAppearance(to: view)
            ThemeRepaint.request(view, roots: { () -> [NSView] in [view] }, scope: self, animated: false, lazy: false)
        }
    }

    /// Makes `window` (a main window or a panel it owns) draw in this scope:
    /// its appearance, and every view in it that roots no other scope.
    public func adopt(_ window: NSWindow) {
        ThemeRepaint.batch {
            if let previous = ThemeScopeRegistry.scope(of: window), previous !== self { previous.windows.remove(window) }
            ThemeScopeRegistry.setScope(self, of: window)
            windows.add(window)
            window.appearance = appearance
            if let content = window.contentView { ThemeRepaint.request(content, roots: { () -> [NSView] in [content] }, scope: self, animated: false, lazy: false) }
        }
    }

    /// Calls `responder.themeDidChange()` after every change of this scope's
    /// colors while it lives.
    public func addResponder(_ responder: any ThemeResponsive) {
        responders.add(responder)
    }

    /// Stops calling `responder.themeDidChange()`.
    public func removeResponder(_ responder: any ThemeResponsive) {
        responders.remove(responder)
    }

    /// Runs `body` with this scope's colors active for `Palette` and its
    /// appearance as the drawing appearance (layer owners without a view).
    public func perform<T>(_ body: () -> T) -> T {
        ThemeContext.push(self)
        defer { ThemeContext.pop() }
        var result: T?
        appearance.performAsCurrentDrawingAppearance { result = body() }
        // The block runs synchronously, so `result` is set; otherwise run `body` without the appearance.
        return result ?? body()
    }

    /// A root view takes an explicit appearance only where its scope's
    /// light/dark differs from what it inherits, so AppKit controls inside a
    /// light workspace in a dark room draw light.
    private func applyAppearance(to view: NSView) {
        let inherited = parent?.tokens.isDark ?? tokens.isDark
        view.appearance = inherited == tokens.isDark ? nil : appearance
    }

    /// Runs the theme hook of every view this scope's colors draw, once: its windows' content
    /// and its roots, without the regions of views that root other scopes (I5: a workspace
    /// switch repaints the room's chrome, never every workspace's content). Animated: each layer
    /// color the hooks change blends from the color on screen (`ThemeRepaint`).
    /// - Parameter previous: The tokens painted before (nil: unknown).
    private func repaint(animated: Bool, from previous: ThemeTokens?) {
        paintRevision += 1
        let now = tokens
        // A non-opaque window's shadow follows its content's alpha.
        let shadowMoved = previous.map { $0.backgroundOpacity != now.backgroundOpacity || $0.isDark != now.isDark } ?? true
        ThemeRepaint.beforeHooks { [weak self] in
            guard let self else { return }
            for window in self.windows.allObjects {
                if window.appearance?.name != self.appearance.name { window.appearance = self.appearance }
                if shadowMoved { window.invalidateShadow() }
            }
        }
        ThemeRepaint.request(self, roots: { [weak self] in
            guard let self else { return [] }
            return self.windows.allObjects.compactMap(\.contentView) + self.roots.allObjects
        }, scope: self, animated: animated)
    }
}
