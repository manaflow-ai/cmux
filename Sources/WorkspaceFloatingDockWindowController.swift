import AppKit
import SwiftUI

/// Owns the native child panel for one workspace floating Dock.
@MainActor
final class WorkspaceFloatingDockWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = "cmux.workspace.float"

    let dock: WorkspaceFloatingDock
    private weak var parentWindow: NSWindow?
    private let onCloseRequest: (UUID) -> Void
    private var isApplyingModelFrame = false

    init(
        dock: WorkspaceFloatingDock,
        parentWindow: NSWindow,
        onCloseRequest: @escaping (UUID) -> Void
    ) {
        self.dock = dock
        self.parentWindow = parentWindow
        self.onCloseRequest = onCloseRequest

        let panel = NSPanel(
            contentRect: Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = dock.title
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 220)
        panel.contentView = UserSizedWindowHostingView(
            rootView: WorkspaceFloatingDockContentView(dock: dock),
            minimumContentSize: NSSize(width: 320, height: 220)
        )
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(focus: Bool) {
        guard let panel = window, let parentWindow else { return }
        panel.title = dock.title
        if !panel.isVisible {
            if panel.parent !== parentWindow {
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            applyModelFrame()
            panel.orderFront(nil)
        }
        dock.isPresented = true
        dock.store.setVisibleInUI(true)
        if focus {
            panel.makeKeyAndOrderFront(nil)
            _ = dock.store.focusFirstControl()
        }
    }

    func hide() {
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        window?.orderOut(nil)
    }

    func teardown() {
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        if let window, let parent = window.parent {
            parent.removeChildWindow(window)
        }
        window?.orderOut(nil)
        window?.delegate = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest(dock.id)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        captureModelFrame()
    }

    func windowDidResize(_ notification: Notification) {
        captureModelFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        dock.ownsInputFocus = true
    }

    func windowDidResignKey(_ notification: Notification) {
        dock.ownsInputFocus = false
    }

    private func applyModelFrame() {
        guard let panel = window, let parentWindow else { return }
        isApplyingModelFrame = true
        panel.setFrame(Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow), display: false)
        isApplyingModelFrame = false
    }

    private func captureModelFrame() {
        guard !isApplyingModelFrame, let panel = window, let parentWindow else { return }
        dock.frame = CGRect(
            x: panel.frame.minX - parentWindow.frame.minX,
            y: panel.frame.minY - parentWindow.frame.minY,
            width: panel.frame.width,
            height: panel.frame.height
        )
    }

    private static func screenFrame(relativeFrame: CGRect, parentWindow: NSWindow) -> CGRect {
        CGRect(
            x: parentWindow.frame.minX + relativeFrame.minX,
            y: parentWindow.frame.minY + relativeFrame.minY,
            width: relativeFrame.width,
            height: relativeFrame.height
        )
    }
}
