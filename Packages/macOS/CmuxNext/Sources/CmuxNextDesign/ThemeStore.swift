public import AppKit
public import CmuxTheme
public import Observation
import Synchronization

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

    @ObservationIgnored private let publishesGlobally: Bool
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
        self.input = input
        let derived = ThemeTokens.derive(from: input)
        guard derived != tokens else { return false }
        tokens = derived
        generation += 1
        if publishesGlobally {
            ThemeSnapshot.store(derived)
            // Room, workspace and terminal scopes inherit from the app scope.
            ThemeScope.app.storeDidChange()
            for window in NSApp?.windows ?? [] { refresh(window) }
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
        if publishesGlobally { repaintAll() }
        return true
    }

    /// Repaints every window and responder as a theme change does, for a
    /// change that moves resolved colors or widths without a new theme
    /// (`appearance.borders`).
    public func repaintAll() {
        for window in NSApp?.windows ?? [] { refresh(window) }
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
    private func refresh(_ window: NSWindow) {
        window.appearance = window.themeScope.appearance
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
