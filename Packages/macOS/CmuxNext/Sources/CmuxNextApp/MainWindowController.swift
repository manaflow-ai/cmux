import AppKit
import CmuxNextActions
import CmuxNextDesign

/// Owns the single shell window.
final class MainWindowController: NSWindowController {
    init(model: ShellModel, registry: ActionRegistry, environment: AppEnvironment) {
        let window = ShellWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.registry = registry
        window.title = Strings.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = Palette.windowBackground
        window.minSize = NSSize(width: 520, height: 320)
        window.contentView = ShellRootView(model: model, environment: environment)
        window.setFrameAutosaveName("CmuxNextMainWindow")
        if !window.setFrameUsingName("CmuxNextMainWindow") {
            window.center()
        }
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Routes key equivalents through the action registry before any view (and
/// later the terminal) sees them: step 2 of the keyboard order in shell.md.
final class ShellWindow: NSWindow {
    weak var registry: ActionRegistry?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if registry?.performShortcut(for: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
