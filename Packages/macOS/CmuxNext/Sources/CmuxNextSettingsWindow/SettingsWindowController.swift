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
        window.backgroundColor = Palette.windowBackground
        window.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        window.setFrameAutosaveName("cmux.settings")
        window.model = model
        ThemeStore.shared.adopt(window)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on `section` (nil keeps the last one).
    public func present(section: SettingsSection? = nil) {
        if let section {
            model.query = ""
            model.selection = section
        }
        guard let window else { return }
        ThemeStore.shared.adopt(window)
        WindowPlacement.present(window)
    }

    public func windowWillClose(_ notification: Notification) {
        model.cancelRecording()
        onClose?()
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
