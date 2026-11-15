public import AppKit

/// Debug: Toast Playground (`debug.toastPlayground`, DEV and NIGHTLY; Lawrence 2026-11-13: "we need to
/// improve all our toasts/prompts, make a swift playground for me to pick my favorite"): ``show(themes:)``
/// opens a gallery of the toast styles (``CmuxToastStyle``), each with every kind of toast in light and
/// dark, or raises it when open. Fire it shows a style as real toasts in the window the person works in;
/// Pick makes it the style of every toast and prompt (``CmuxToastCenter/pick(_:)``).
///
/// ```swift
/// let playground = CmuxToastPlaygroundWindow(center: .shared, window: { windows.active?.window })
/// playground.show(themes: CmuxToastPlaygroundThemes(colors: catalog.colors))
/// ```
@MainActor
public final class CmuxToastPlaygroundWindow {
    private let center: CmuxToastCenter
    private let target: @MainActor () -> NSWindow?
    private var window: NSWindow?

    /// - Parameters:
    ///   - center: The toasts' center (the app's shared one).
    ///   - window: The window Fire it shows toasts in (the active one); nil shows them in the playground.
    public init(center: CmuxToastCenter, window: @escaping @MainActor () -> NSWindow?) {
        self.center = center
        target = window
    }

    /// The playground's window, once opened (tests, captures).
    public var shownWindow: NSWindow? { window }

    /// Opens the playground (its sheets in `themes`, the styles Debug Settings > Toasts > Playground shows
    /// picks), or brings it to the front with those styles.
    public func show(themes: CmuxToastPlaygroundThemes) {
        let window = window ?? makeWindow()
        self.window = window
        let center = center, target = target
        let view = CmuxToastPlaygroundView(center: center, themes: themes,
                                           focus: CmuxToastTunables.playgroundFocus.value(in: center.tunables)) { [weak window] style in
            guard let shownIn = target() ?? window else { return }
            for var toast in CmuxToastPlaygroundSamples.fired {
                toast.style = style
                toast.id = "toastPlayground.fire.\(toast.id)"
                center.show(toast, in: shownIn)
            }
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        view.enter()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Toast Playground"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1000, height: 500)
        window.setAccessibilityIdentifier("cmux.toastPlayground")
        window.center()
        return window
    }
}
