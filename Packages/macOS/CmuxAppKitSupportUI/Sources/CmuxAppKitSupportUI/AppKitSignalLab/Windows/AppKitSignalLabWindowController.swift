#if canImport(AppKit)

import AppKit

@MainActor
final class AppKitSignalLabWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppKitSignalLabModel

    init(model: AppKitSignalLabModel = AppKitSignalLabModel()) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.signalLab.windowTitle", defaultValue: "Signal Todo List")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.appKitSignalsLab")
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        window.contentViewController = AppKitSignalLabViewController(model: model)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#endif
