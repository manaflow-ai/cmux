import AppKit
import SwiftUI

/// Window controller for the cross-workspace task queue.
@MainActor
final class WorkspaceTaskQueueWindowController: ReleasingWindowController {
    static let shared = WorkspaceTaskQueueWindowController()

    private let model = WorkspaceTaskQueueModel()

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.workspaceTaskQueue")
        window.title = String(localized: "taskQueue.windowTitle", defaultValue: "Task Queue")
        window.center()
        window.contentView = NSHostingView(rootView: WorkspaceTaskQueueView(model: model))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        let window = managedWindow()
        model.refresh()
        if !window.isVisible { window.center() }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
