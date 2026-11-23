public import AppKit

/// Debug: Tooltip Gallery (`debug.tooltipGallery`, DEV and NIGHTLY; Lawrence 2026-11-20: "tooltips everywhere needs
/// to be redesigned to be better and consistent"). It draws every tooltip state (``TooltipGallerySample``: text only,
/// a shortcut, several keys, wrapping, wrapping with keys, Reduce Transparency) with the real tooltip surface and
/// content, in a light, a dark and a strong accent theme side by side, and a live toolbar in each whose buttons show
/// the real tooltip on hover (the delay, then the warm group's hand-off). It opens from the palette
/// (`debug.tooltipGallery`) and from the Toast Playground's button, which works before the palette knows the action.
///
/// ```swift
/// let gallery = TooltipGalleryWindow()
/// gallery.show(themes: CmuxToastPlaygroundThemes(colors: catalog.colors))
/// ```
@MainActor
public final class TooltipGalleryWindow {
    private var window: NSWindow?

    public init() {}

    /// The gallery's window, once opened (tests, captures).
    public var shownWindow: NSWindow? { window }

    /// Opens the gallery with its light and dark columns in `themes` (and the accent column's own theme), or brings
    /// it to the front.
    public func show(themes: CmuxToastPlaygroundThemes) {
        let window = window ?? makeWindow()
        self.window = window
        window.contentView = TooltipGalleryView(columns: Self.columns(themes))
        window.makeKeyAndOrderFront(nil)
    }

    /// Light, dark, and a saturated accent theme the legibility walk must work hardest in.
    static func columns(_ themes: CmuxToastPlaygroundThemes) -> [(title: String, isDark: Bool, theme: (spec: ThemeSpec?, input: ThemeInput)?)] {
        let accent = ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF))
        return [
            ("Light", false, themes.theme(isDark: false)),
            ("Dark", true, themes.theme(isDark: true)),
            ("Accent", true, (ThemeSpec("Stress Purple"), accent)),
        ]
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tooltip Gallery"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 400)
        window.setAccessibilityIdentifier("cmux.tooltipGallery")
        window.center()
        return window
    }
}
