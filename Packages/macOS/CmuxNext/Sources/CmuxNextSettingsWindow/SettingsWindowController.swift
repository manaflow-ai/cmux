public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
import SwiftUI

/// The Settings window (Cmd-, and the app menu): one window per app, built
/// from `SettingsSchema`, SwiftUI inside an `NSHostingView` (a low-frequency
/// form surface, architecture.md section 3). Colors follow the Ghostty
/// theme; no-activate launches place it without taking the keyboard
/// (`WindowPlacement`).
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public let model: SettingsWindowModel
    /// Runs once after the window closed (the owner releases it).
    public var onClose: (() -> Void)?

    public init(model: SettingsWindowModel) {
        self.model = model
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = SettingsWindowStrings.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        window.setFrameAutosaveName("cmux.settings")
        window.model = model
        super.init(window: window)
        window.delegate = self
        // Theme and background first: changing the window background while
        // AppKit installs the content view puts the content above the
        // titlebar, which hides the close button (lane 20).
        setThemeScope(SettingsTheme.shared.scope)
        window.backgroundColor = SettingsTheme.shared.scope.perform { Palette.utilityWindowBackground }
        window.contentView = SettingsContentView(rootView: SettingsRootView(model: model))
    }

    /// Draws the window in `scope`: the App passes the scope of the main
    /// window Settings was opened from (its room theme). Default: the app
    /// theme (the Ghostty config).
    public func setThemeScope(_ scope: ThemeScope) {
        SettingsTheme.shared.follow(scope)
        guard let window else { return }
        scope.adopt(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on `section` (nil keeps the last one), or scrolled
    /// to `anchor` with its highlight (`openSettings setting:`).
    public func present(section: SettingsSection? = nil, anchor: SettingsAnchor? = nil) {
        if let anchor {
            model.open(anchor)
        } else if let section {
            model.select(section, layout: SettingsWindowLayout.tunable.value)
        }
        guard let window else { return }
        SettingsTheme.shared.scope.adopt(window)
        WindowPlacement.present(window)
    }

    public func windowWillClose(_ notification: Notification) {
        model.cancelRecording()
        onClose?()
    }

    /// Recording stops when the window loses the keys, so the system-wide
    /// hot keys it suspended do not stay off behind another window or app.
    public func windowDidResignKey(_ notification: Notification) {
        model.cancelRecording()
    }
}

/// The hosting view; it repaints the window background with the scope's
/// colors on every theme change.
final class SettingsContentView: NSHostingView<SettingsRootView> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let color = performWithTheme { Palette.utilityWindowBackground }
        if let window, window.backgroundColor != color { window.backgroundColor = color }
    }
}

/// Routes every key-down to the shortcut recorder while it records, before
/// menus see key equivalents, so a recorded Cmd-W neither closes the window
/// nor runs an action.
final class SettingsWindow: NSWindow {
    weak var model: SettingsWindowModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let model, model.recorder != nil, event.type == .keyDown { return model.handleRecorderKey(event) }
        return super.performKeyEquivalent(with: event)
    }

    /// Plain keys (Escape, Delete, Return) reach the recorder before the
    /// focused field.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let model, model.recorder != nil, model.handleRecorderKey(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let model, model.recorder != nil { return model.cancelRecording() }
        close()
    }
}
