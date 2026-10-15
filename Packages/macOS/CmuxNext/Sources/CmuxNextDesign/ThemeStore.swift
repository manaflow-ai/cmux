public import AppKit
public import CmuxTheme
public import Observation
import CmuxNextCompat

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
@Observable
public final class ThemeStore {
    public static let shared = ThemeStore(publishesGlobally: true)

    public private(set) var tokens: ThemeTokens
    public private(set) var input: ThemeInput
    /// Bumps on every applied change (tests, diagnostics).
    public private(set) var generation = 0
    /// The app theme when `appearance.appTheme` names one; nil follows each scope's terminal
    /// theme (`ThemeTokens.app`). Web pages read it through `WebTheme`.
    public private(set) var appTheme: AppTheme?
    /// `appearance.accent`: every scope derives its tokens with it (`ThemeInput.accent`).
    public private(set) var accent: ThemeAccent = .neutral
    /// Art Color (`appearance.accent: "art"`): each scope's accent takes the hue of the art it
    /// shows (`BackdropArt.accentHue`), over the theme's own.
    public private(set) var accentFollowsArt = false

    @ObservationIgnored private let publishesGlobally: Bool
    /// The Ghostty config's colors reached the windows once: later changes are color changes that
    /// animate (`ColorTransition.current` is instant until then, so launch never fades in).
    @ObservationIgnored public private(set) var hasAppliedConfig = false
    @ObservationIgnored private let responders = NSHashTable<AnyObject>.weakObjects()

    public init(input: ThemeInput = .ghosttyDefault) {
        self.input = input
        tokens = ThemeTokens.derive(from: input)
        publishesGlobally = false
    }

    private init(publishesGlobally: Bool) {
        input = .ghosttyDefault
        tokens = .fallback
        self.publishesGlobally = publishesGlobally
    }

    /// The appearance that matches the theme, for windows and panels.
    public var appearance: NSAppearance {
        NSAppearance(named: tokens.isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    /// Applies a theme read from the Ghostty config. Returns false when the
    /// derived tokens did not change (no invalidation happens then).
    @discardableResult
    public func apply(_ input: ThemeInput) -> Bool {
        let firstConfig = !hasAppliedConfig
        defer { if publishesGlobally { hasAppliedConfig = true } }
        var input = input
        input.accent = accent
        let previous = self.input
        self.input = input
        let derived = ThemeTokens.derive(from: input)
        guard derived != tokens else {
            // A color no token reads (`selection-foreground`) still reaches the scopes' input and
            // the store's observers (Settings' Ghostty preview); nothing repaints.
            if input != previous {
                generation += 1
                if publishesGlobally { ThemeScope.app.storeDidChange() }
            }
            return false
        }
        tokens = derived
        generation += 1
        if publishesGlobally {
            ThemeSnapshot.store(derived)
            // Room, workspace and terminal scopes inherit from the app scope.
            ThemeScope.app.storeDidChange()
            // A theme, light/dark or Ghostty config change recolors every window in place: the
            // whole window crossfades (terminal surfaces have no color to blend one by one).
            // Not the first config of the launch: windows show it as their first colors.
            for window in NSApp?.windows ?? [] { refresh(window, crossfade: !firstConfig) }
        }
        for responder in responders.allObjects {
            (responder as? any ThemeResponsive)?.themeDidChange()
        }
        return true
    }

    /// Sets the app theme apart from the terminal theme (nil: follow it), and repaints so every
    /// page re-applies its `--cmux-app-*` tokens. Returns false when nothing changed.
    @discardableResult
    public func setAppTheme(_ theme: AppTheme?) -> Bool {
        guard theme != appTheme else { return false }
        appTheme = theme
        generation += 1
        if publishesGlobally { repaintAll(crossfade: true) }
        return true
    }

    /// Sets where the accent comes from and re-derives every scope's tokens with it. Returns
    /// false when the accent did not change.
    @discardableResult
    public func setAccent(_ accent: ThemeAccent) -> Bool {
        guard accent != self.accent else { return false }
        self.accent = accent
        // Two accents can give the config's theme the same tokens (`theme` and `magenta` under
        // Rose Pine) while an overridden scope's theme still differs, so scopes re-derive anyway.
        if !apply(input), publishesGlobally {
            ThemeScope.app.storeDidChange()
            repaintAll(crossfade: true)
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
        if publishesGlobally {
            ThemeScope.app.accentSourceDidChange()
            repaintAll(crossfade: true)
        }
        return true
    }

    /// Repaints every window and responder as a theme change does, for a
    /// change that moves resolved colors or widths without a new theme
    /// (`appearance.borders`).
    /// - Parameter crossfade: The change recolors (app theme, accent): windows crossfade
    ///   (`appearance.colorTransition`). Layout changes (borders, fonts) repaint at once.
    public func repaintAll(crossfade: Bool = false) {
        for window in NSApp?.windows ?? [] { refresh(window, crossfade: crossfade) }
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
    /// config stays light).
    private func refresh(_ window: NSWindow, crossfade: Bool = false) {
        window.appearance = window.themeScope.appearance
        if crossfade, window.isVisible { ColorTransition.current.crossfade(window.contentView?.layer) }
        if let contentView = window.contentView { Self.invalidate(contentView) }
        window.invalidateShadow()
    }

    /// Views already re-resolve colors when their effective appearance
    /// changes (the one hook every chrome view implements), and a theme
    /// change is exactly that: the colors behind the dynamic tokens moved.
    /// A dark-to-dark theme switch leaves the appearance name unchanged, so
    /// AppKit would not call it; the store does.
    private static func invalidate(_ view: NSView) {
        ThemeScope.invalidate(view)
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
