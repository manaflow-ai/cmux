public import AppKit
public import CmuxTheme
public import Observation
import CmuxNextCompat
public import CmuxNextDesignTokens

/// A non-view object (controller, layer owner) that caches resolved theme
/// colors and must refresh them on a theme change. Views need nothing: the
/// store re-runs their appearance handlers.
public protocol ThemeResponsive: AnyObject {
    func themeDidChange()
}

/// The live theme. The App feeds it the Ghostty config on launch and on
/// every config reload; every chrome color (`Palette`) reads from it.
///
/// On a change it (1) publishes the new tokens for `Palette`'s dynamic
/// colors, (2) gives every window the matching light or dark appearance,
/// (3) invalidates display and layout of every view and calls its
/// `viewDidChangeEffectiveAppearance`, so `updateLayer`, `draw`, `layout`
/// and appearance handlers re-resolve, and (4) calls registered
/// `ThemeResponsive` objects (non-view owners of resolved colors). Views
/// never branch on the theme themselves.
///
/// The app's store is the one ``ThemeScope/app`` roots on (`ThemeScope.app.store`); the
/// composition root (`AppServices.themeStore`) hands that reference to the App's owners, and a
/// scope reads its tree's store as ``ThemeScope/store``. Tests make their own (`ThemeStore()`).
@Observable
public final class ThemeStore {

    public private(set) var tokens: ThemeTokens
    /// The colors the chrome derives from: the app theme's (`appearance.appTheme`) when it names
    /// one, else the Ghostty config's (``configInput``). Scopes without a theme of their own
    /// inherit it.
    public private(set) var input: ThemeInput
    /// The Ghostty config's colors (the terminal theme) as last applied, whatever the app theme.
    public private(set) var configInput: ThemeInput
    /// The app theme's colors while `appearance.appTheme` names one.
    @ObservationIgnored private var appInput: ThemeInput?
    /// Bumps on every applied change (tests, diagnostics).
    public private(set) var generation = 0
    /// The app theme when `appearance.appTheme` names one; nil follows each scope's terminal
    /// theme (`ThemeTokens.app`). Web pages read it through `WebTheme`; the native chrome derives
    /// from its colors (``input``).
    public private(set) var appTheme: AppTheme?
    /// `appearance.accent`: every scope derives its tokens with it (`ThemeInput.accent`).
    public private(set) var accent: ThemeAccent = .neutral
    /// Art Color (`appearance.accent: "art"`): each scope's accent takes the hue of the art it
    /// shows (`BackdropArt.accentHue`), over the theme's own.
    public private(set) var accentFollowsArt = false
    /// `appearance.machineColors`: the colors people picked for machines (`MachineColor.color`).
    public private(set) var machineColors = MachineColorOverrides.none

    @ObservationIgnored private let publishesGlobally: Bool
    /// The root scope of this store's tree (``ThemeScope/app`` for the app's store): it tells its
    /// subtree after a change.
    @ObservationIgnored weak var root: ThemeScope?
    /// Bumped when any theme scope's shown picture or tuning changes (``ThemeScope/shownWindowOpacity``
    /// readers observe it).
    @ObservationIgnored package let backdropRevision = BackdropRevision()
    /// The Ghostty config's colors reached the windows once: later changes are color changes that
    /// animate (`ColorTransition.current` is instant until then, so launch never fades in).
    @ObservationIgnored public private(set) var hasAppliedConfig = false
    @ObservationIgnored private let responders = NSHashTable<AnyObject>.weakObjects()

    public init(input: ThemeInput = .ghosttyDefault) {
        self.input = input
        configInput = input
        tokens = ThemeTokens.derive(from: input)
        publishesGlobally = false
    }

    /// The app's store: a change repaints every window. Only ``ThemeScope/app`` makes one.
    init(publishesGlobally: Bool) {
        input = .ghosttyDefault
        configInput = .ghosttyDefault
        tokens = .fallback
        self.publishesGlobally = publishesGlobally
        // The app's store comes first at launch (ThemeBridge.start): the UI font (Inter) is
        // registered and its page script read off the main thread before chrome or a page needs them.
        if publishesGlobally { BundledFonts.prepareInBackground() }
    }

    /// The appearance that matches the theme, for windows and panels.
    public var appearance: NSAppearance {
        NSAppearance(named: tokens.isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    /// Applies a theme read from the Ghostty config. Returns false when the
    /// derived tokens did not change (no invalidation happens then). While an app theme is set
    /// the chrome keeps its colors; only ``configInput`` changes.
    @discardableResult
    public func apply(_ input: ThemeInput) -> Bool {
        let firstConfig = !hasAppliedConfig
        defer { if publishesGlobally { hasAppliedConfig = true } }
        var input = input
        input.accent = accent
        let previousConfig = configInput
        configInput = input
        let changed = applyChrome(firstConfig: firstConfig)
        // Under an app theme the chrome holds still, yet readers of the config's own colors
        // (Settings' "Use Ghostty Config" swatch) watch `generation`, and the terminals draw them.
        if !changed, appInput != nil, configInput != previousConfig {
            generation += 1
            root?.configDidChange()
        }
        return changed
    }

    /// Derives the chrome from the app theme's colors, else the config's. `firstConfig`: the
    /// launch's first colors, which windows show at once (default: until the config's first apply).
    private func applyChrome(firstConfig: Bool? = nil) -> Bool {
        let firstConfig = firstConfig ?? !hasAppliedConfig
        var input = appInput ?? configInput
        input.accent = accent
        let previous = self.input
        self.input = input
        let derived = ThemeTokens.derive(from: input)
        guard derived != tokens else {
            // A color no token reads (`selection-foreground`) still reaches the scopes' input and
            // the store's observers (Settings' Ghostty preview); nothing repaints.
            if input != previous {
                generation += 1
                root?.storeDidChange()
            }
            return false
        }
        tokens = derived
        generation += 1
        // Only the app's store repaints every window; a test's tree (``ThemeScope/init(root:)``) recomputes.
        if !publishesGlobally { root?.storeDidChange() }
        if publishesGlobally {
            ThemeSnapshot.store(derived)
            // Room, workspace and terminal scopes inherit from the app scope.
            // A theme, light/dark or Ghostty config change recolors every window in place: its
            // layer colors blend from the ones on screen (colors drawn in draw(_:) and terminal
            // surfaces switch at once). Not the first config of the launch: windows show it as
            // their first colors.
            ThemeRepaint.batch {
                root?.storeDidChange()
                for window in NSApp?.windows ?? [] { refresh(window, crossfade: !firstConfig) }
            }
        }
        for responder in responders.allObjects {
            (responder as? any ThemeResponsive)?.themeDidChange()
        }
        return true
    }

    /// Sets the app theme apart from the terminal theme from its colors (nil: follow the terminal
    /// theme): the native chrome derives from them, and every page re-applies its `--cmux-app-*`
    /// tokens. The accent is the store's (``accent``). Returns false when nothing changed.
    /// - Parameter input: The app theme's resolved colors (its light or dark variant).
    @discardableResult
    public func setAppTheme(from input: ThemeInput?) -> Bool {
        var input = input
        input?.accent = accent
        guard input != appInput else { return false }
        appInput = input
        appTheme = input.map(AppTheme.derive)
        generation += 1
        // The chrome's tokens moved: `applyChrome` repaints every window; else only the pages do.
        if !applyChrome(), publishesGlobally { repaintAll(crossfade: true) }
        return true
    }

    /// Sets cmux.json's window opacity and blur on the config's colors and the app theme's, ahead
    /// of the config reload that brings the terminals along (an Opacity slider step).
    @discardableResult
    public func applyBackground(opacity: Double, blur: Int) -> Bool {
        (configInput.backgroundOpacity, configInput.backgroundBlur) = (opacity, blur)
        if var app = appInput {
            (app.backgroundOpacity, app.backgroundBlur) = (opacity, blur)
            appInput = app
            appTheme = AppTheme.derive(from: app)
        }
        return applyChrome()
    }

    /// Sets where the accent comes from and re-derives every scope's tokens with it. Returns
    /// false when the accent did not change.
    @discardableResult
    public func setAccent(_ accent: ThemeAccent) -> Bool {
        guard accent != self.accent else { return false }
        self.accent = accent
        if var app = appInput {
            app.accent = accent
            appInput = app
            appTheme = AppTheme.derive(from: app)
        }
        configInput.accent = accent
        // Two accents can give the config's theme the same tokens (`theme` and `magenta` under
        // Rose Pine) while an overridden scope's theme still differs, so scopes re-derive anyway.
        if !applyChrome(), publishesGlobally {
            ThemeRepaint.batch {
                root?.storeDidChange()
                repaintAll(crossfade: true)
            }
        }
        return true
    }

    /// Turns Art Color on or off and re-derives every scope's tokens. Returns false when it did
    /// not change.
    @discardableResult
    public func setAccentFollowsArt(_ follows: Bool) -> Bool {
        guard follows != accentFollowsArt else { return false }
        accentFollowsArt = follows
        generation += 1
        // A test's tree (``ThemeScope/init(root:)``) recomputes, as for a theme change (`applyChrome`).
        if !publishesGlobally { root?.accentSourceDidChange() }
        if publishesGlobally {
            ThemeRepaint.batch {
                root?.accentSourceDidChange()
                repaintAll(crossfade: true)
            }
        }
        return true
    }

    /// Sets the colors people picked for machines and repaints, so every machine mark (sidebar
    /// rows, tab badges) redraws in them. Returns false when they did not change.
    @discardableResult
    public func setMachineColors(_ colors: MachineColorOverrides) -> Bool {
        guard colors != machineColors else { return false }
        machineColors = colors
        generation += 1
        if publishesGlobally { repaintAll(crossfade: true) }
        return true
    }

    /// Repaints every window and responder as a theme change does, for a
    /// change that moves resolved colors or widths without a new theme
    /// (`appearance.borders`).
    /// - Parameter crossfade: The change recolors (app theme, accent): layer colors blend
    ///   (`appearance.colorTransition`). Layout changes (borders, fonts) repaint at once.
    public func repaintAll(crossfade: Bool = false) {
        ThemeRepaint.batch {
            for window in NSApp?.windows ?? [] { refresh(window, crossfade: crossfade) }
        }
        for responder in responders.allObjects {
            (responder as? any ThemeResponsive)?.themeDidChange()
        }
    }

    /// Calls `responder.themeDidChange()` after every change while it lives.
    public func addResponder(_ responder: any ThemeResponsive) {
        responders.add(responder)
    }

    /// Gives a new window or panel the app theme's appearance, for UI that
    /// belongs to no room (onboarding, update sheet). Windows and panels of a
    /// room use `ThemeScope.adopt` or `NSWindow.adoptThemeScope(of:)`.
    /// Existing windows are refreshed by `apply`.
    public func adopt(_ window: NSWindow) {
        window.appearance = appearance
    }

    /// Each window takes its own scope's appearance (a light room in a dark
    /// config stays light) and every view in it runs its theme hook once: a
    /// config change can move every scope's colors, and colors outside any
    /// scope follow the app theme. A recolor blends each layer color from the
    /// one on screen (`ThemeRepaint`); a layout change (borders, fonts) lays
    /// the views out again and applies at once.
    private func refresh(_ window: NSWindow, crossfade: Bool = false) {
        ThemeRepaint.beforeHooks { [weak window] in
            guard let window else { return }
            window.appearance = window.themeScope.appearance
            window.invalidateShadow()
        }
        if let contentView = window.contentView {
            ThemeRepaint.request(contentView, roots: { () -> [NSView] in [contentView] }, scope: nil, animated: crossfade, layout: !crossfade)
        }
    }
}

/// Process-wide copy of the current tokens, readable from any thread
/// (NSColor dynamic providers may resolve off the main thread).
nonisolated enum ThemeSnapshot {
    private static let current = Mutex(ThemeTokens.fallback)

    static var tokens: ThemeTokens { current.withLock { $0 } }

    static func store(_ tokens: ThemeTokens) {
        current.withLock { $0 = tokens }
    }
}
