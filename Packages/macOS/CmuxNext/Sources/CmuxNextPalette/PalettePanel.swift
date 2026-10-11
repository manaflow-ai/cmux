import AppKit
import CmuxNextDesign

/// Borderless floating panel that can become key without activating other
/// windows' chrome, and routes key-downs to the palette first.
final class PalettePanel: ActiveAppKeyPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            // Created ahead of the first open (`PaletteController.prepare`),
            // so the window-server window is made then, not on open.
            defer: false
        )
        // Takes the scope of the window it opens over (`PaletteController.present`).
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.commandPalette")
    }

    override var canBecomeMain: Bool { false }

    /// True while the shortcut recorder listens: every chord is its input,
    /// so no main-menu item or responder sees it.
    var capturesKeyEquivalents: (() -> Bool)?
    /// One chord the palette takes before any main-menu item: Cmd-W on a
    /// row with a close command closes that row's object, never the tab
    /// behind the palette.
    var capturesKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, capturesKeyEquivalents?() == true || capturesKeyEquivalent?(event) == true,
           keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Key-downs no responder handled (AppKit beeps for each). The palette
    /// handles every key it maps, so this stays 0 (`debug.key` reports it).
    private(set) var unhandledKeyDowns = 0

    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)) { unhandledKeyDowns += 1 }
        super.noResponder(for: eventSelector)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc is handled by keyHandler; swallow the responder-chain fallback.
    }
}
