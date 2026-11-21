public import AppKit

/// Debug: Keycap Playground (`debug.keycapPlayground`, DEV and NIGHTLY; Lawrence 2026-11-16 on the quit dialog's
/// "esc" and "↩" chips: "still looks bad, come up with more variations, think about how linear would do it"). It
/// shows every ``CmuxDialogKeycapStyle`` on a real dialog card's real buttons, Cancel and the default button, at rest,
/// hovered and pressed, in light or dark (a switch at its top). Every dialog draws ``CmuxDialogKeycapStyle/linearKbd``
/// (Lawrence 2026-11-16); the others stay here to compare. It opens from the palette (`debug.keycapPlayground`) and
/// from the Toast Playground's Keycap Playground button, which works before the palette knows the action.
///
/// ```swift
/// let playground = CmuxKeycapPlaygroundWindow()
/// playground.show(themes: CmuxToastPlaygroundThemes(colors: catalog.colors))
/// ```
@MainActor
public final class CmuxKeycapPlaygroundWindow {
    private var window: NSWindow?

    public init() {}

    /// The playground's window, once opened (tests, captures).
    public var shownWindow: NSWindow? { window }

    /// Opens the playground with its sheets in `themes`, in the app's appearance now, or brings it to the front so.
    public func show(themes: CmuxToastPlaygroundThemes) {
        let window = window ?? makeWindow()
        self.window = window
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        fill(window, themes: themes, isDark: isDark)
        window.makeKeyAndOrderFront(nil)
    }

    private func fill(_ window: NSWindow, themes: CmuxToastPlaygroundThemes, isDark: Bool) {
        window.contentView = CmuxKeycapPlaygroundView(themes: themes, isDark: isDark) { [weak self, weak window] dark in
            guard let self, let window else { return }
            fill(window, themes: themes, isDark: dark)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Keycap Playground"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 400)
        window.setAccessibilityIdentifier("cmux.keycapPlayground")
        window.center()
        return window
    }
}
