public import AppKit
public import CmuxTheme
import CmuxNextWakeups
public import CmuxNextDesignTokens
public import CmuxNextAppearance

/// How an app overlay that floats over content (palette, hover card, find
/// and prompt bars, the tab drag's drop target) is drawn. One decision for
/// every OS and accessibility setting.
public enum OverlayMaterial: Equatable, Sendable {
    /// Real Liquid Glass (`NSGlassEffectView`, macOS 26 and later).
    case liquidGlass
    /// Before Liquid Glass: a behind-window blur (`NSVisualEffectView`)
    /// with a Ghostty-derived tint and a hairline border.
    case vibrancy
    /// Reduce Transparency: an opaque Ghostty-derived fill with a hairline
    /// border, no blur and no glass.
    case opaque

    /// The material for an OS that has (or lacks) Liquid Glass and the
    /// user's Reduce Transparency setting.
    public static func select(liquidGlassAvailable: Bool, reduceTransparency: Bool) -> OverlayMaterial {
        if reduceTransparency { return .opaque }
        return liquidGlassAvailable ? .liquidGlass : .vibrancy
    }

    /// Whether this OS has Liquid Glass (macOS 26 and later). A runtime
    /// check, so the selection stays testable for every OS.
    public static var liquidGlassAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    /// The material for this Mac now.
    @MainActor public static var current: OverlayMaterial { current(in: .shared) }

    /// The material for this Mac under `reduceTransparency`.
    @MainActor public static func current(in reduceTransparency: ReduceTransparency) -> OverlayMaterial {
        select(liquidGlassAvailable: liquidGlassAvailable, reduceTransparency: reduceTransparency.isEnabled)
    }
}

/// The Reduce Transparency state overlay surfaces read, and the one
/// observer that redraws the live surfaces when it changes. Surfaces
/// register themselves; nothing polls. `shared` follows the system
/// setting; tests inject the state through `override` or their own source.
@MainActor
public final class ReduceTransparency {
    /// This Mac's setting; the app's ``AppearanceSignals`` say when it may have changed.
    public static let shared = ReduceTransparency(
        system: { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
        changes: DesignSettings.shared.signals
    )

    /// Always opaque: for a card floating over content that must not show through it.
    public static let alwaysOpaque = ReduceTransparency(system: { true })

    /// Pins the state (tests, Debug); nil follows `system`. Changing it
    /// redraws every live surface at once.
    public var override: Bool? {
        didSet { if override != oldValue { refreshSurfaces() } }
    }

    /// Whether overlays draw opaque now.
    public var isEnabled: Bool { override ?? system() }

    private let system: @MainActor () -> Bool
    private let changes: AppearanceSignals?
    private let surfaces = NSHashTable<OverlaySurfaceView>.weakObjects()
    private let cards = NSHashTable<CardSurfaceView>.weakObjects()
    private var observer: AppearanceSignals.Subscription?
    /// The state the registered cards draw; nil before the first card registers.
    private var cardsOpaque: Bool?

    /// `system` reads the setting; `changes` raises ``AppearanceSignals/Signal/displayOptions``
    /// when it may have changed (nil: it never changes but through ``override``).
    public init(system: @escaping @MainActor () -> Bool, changes: AppearanceSignals? = nil) {
        self.system = system
        self.changes = changes
    }

    /// Makes `surface` follow this state until it is deallocated.
    func register(_ surface: OverlaySurfaceView) {
        surfaces.add(surface)
        observeChanges()
    }

    /// Makes a sidebar card's surface follow this state until it is deallocated.
    func register(_ card: CardSurfaceView) {
        cards.add(card)
        if cardsOpaque == nil { cardsOpaque = isEnabled }
        observeChanges()
    }

    private func observeChanges() {
        guard observer == nil else { return }
        observer = changes?.subscribe([.displayOptions], owner: "ReduceTransparency") { [weak self] in
            self?.refreshSurfaces()
        }
    }

    private func refreshSurfaces() {
        for surface in surfaces.allObjects { surface.refreshMaterial() }
        // A display-options signal says the state may have changed: the cards repaint only when it did.
        let opaque = isEnabled
        guard cardsOpaque != nil, opaque != cardsOpaque else { return }
        cardsOpaque = opaque
        for card in cards.allObjects { card.needsDisplay = true } // invalidate: the state changed (the guard above).
    }
}

extension ThemeTokens {
    /// The popup surface (`Palette.popupSurface`): the window background,
    /// opaque, lifted by up to `lift` toward white on a light theme (a white
    /// page gets a white popup, set apart by its hairline and shadow, like
    /// native light menus) and toward the text on a dark one (a lighter
    /// card). A dark lift stops where secondary text would drop below 4.5:1
    /// on a hovered row.
    nonisolated public func opaqueOverlayFill(lift: Double) -> ThemeRGB {
        let page = windowBackground.withAlpha(1)
        let text = textPrimary.withAlpha(1)
        // A dark theme whose text is darker than its page (Hot Dog Stand's red takes dark text)
        // lifts toward white too: lifting toward the text would darken the card under it.
        guard isDark, text.relativeLuminance >= page.relativeLuminance else { return page.mixed(toward: .white, lift) }
        let secondary = textSecondary.withAlpha(1)
        var step = (lift * 100).rounded() / 100
        while step > 0 {
            let fill = page.mixed(toward: text, step)
            if secondary.contrast(with: hoverFill.composited(over: fill)) >= ThemeTokens.minimumTextContrast { return fill }
            step -= 0.01
        }
        return page
    }
}
