public import AppKit
public import CmuxNextDesign
import SwiftUI

/// The Debug Settings window (DEV and NIGHTLY builds; the App gates it):
/// a real titled window in the Settings window's visual language, a
/// sidebar of tunable sections, a search across every tunable, and live
/// edits. Cmd-W closes it, Cmd-F focuses the search, the size is restored
/// (`cmux.debugSettings` autosave), and no-activate launches place it
/// without taking the keyboard (`WindowPlacement`).
public final class DebugSettingsWindowController: NSWindowController, NSWindowDelegate {
    public let model: DebugSettingsModel
    /// Runs once after the window closed (the owner releases it).
    public var onClose: (() -> Void)?

    public init(model: DebugSettingsModel) {
        self.model = model
        let window = DebugSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = DebugSettingsStrings.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 420)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.debugSettings")
        window.setFrameAutosaveName("cmux.debugSettings")
        window.model = model
        super.init(window: window)
        window.delegate = self
        window.contentView = DebugSettingsContentView(rootView: DebugSettingsRootView(model: model))
        setThemeScope(SettingsTheme.shared.scope)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the window in `scope` (the main window it was opened from).
    public func setThemeScope(_ scope: ThemeScope) {
        SettingsTheme.shared.follow(scope)
        guard let window else { return }
        scope.adopt(window)
    }

    /// Shows the window, optionally with a search or a section.
    public func present(query: String? = nil, selection: DebugSettingsSelection? = nil) {
        if let query { model.query = query }
        if let selection { model.selection = selection }
        guard let window else { return }
        SettingsTheme.shared.scope.adopt(window)
        WindowPlacement.present(window)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// The hosting view; it repaints the window background on theme changes.
final class DebugSettingsContentView: NSHostingView<DebugSettingsRootView> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { window?.backgroundColor = Palette.utilityWindowBackground }
    }
}

/// Cmd-F focuses the search, Escape clears the search first and then
/// closes. Cmd-W closes it through the app's shared rule for standalone
/// windows (`StandaloneWindowRule`), like every window of its own.
final class DebugSettingsWindow: NSWindow {
    weak var model: DebugSettingsModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "f" {
            model?.searchFocusRequest += 1
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let model, !model.query.isEmpty {
            model.query = ""
            return
        }
        performClose(nil)
    }
}
