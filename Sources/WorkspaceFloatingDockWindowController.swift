import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Owns the native child panel for one workspace floating Dock.
@MainActor
final class WorkspaceFloatingDockWindowController: NSWindowController, NSWindowDelegate {
    let dock: WorkspaceFloatingDock
    private weak var parentWindow: NSWindow?
    private let onCloseRequest: (UUID) -> Void
    private let glassEffect = WindowGlassEffect()
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
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = dock.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        Self.hideStandardWindowButtons(in: panel)
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.workspace.float.\(dock.id.uuidString)")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 220)
        panel.contentMinSize = NSSize(width: 320, height: 220)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.contentView = WorkspaceFloatingDockHostingView(
            rootView: WorkspaceFloatingDockContentView(
                dock: dock,
                windowActions: WorkspaceFloatingDockWindowActions(
                    close: { onCloseRequest(dock.id) },
                    minimize: { [weak panel] in panel?.miniaturize(nil) },
                    zoom: { [weak panel] in panel?.zoom(nil) }
                )
            ),
            minimumContentSize: NSSize(width: 320, height: 220)
        )
        super.init(window: panel)
        panel.delegate = self
        glassEffect.apply(
            to: panel,
            tintColor: NSColor.windowBackgroundColor.withAlphaComponent(0.16),
            style: .regular
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(focus: Bool) {
        guard let panel = window, let parentWindow else { return }
        panel.title = dock.title
        Self.hideStandardWindowButtons(in: panel)
        if !panel.isVisible {
            if panel.parent !== parentWindow {
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }
        applyModelFrameIfNeeded()
        dock.isPresented = true
        dock.store.setVisibleInUI(true)
        if focus {
            if panel.isMiniaturized {
                panel.deminiaturize(nil)
            }
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
        if let window {
            glassEffect.remove(from: window)
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

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(320, frameSize.width), height: max(220, frameSize.height))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let panel = notification.object as? NSWindow {
            Self.hideStandardWindowButtons(in: panel)
        }
        dock.ownsInputFocus = true
    }

    func windowDidUpdate(_ notification: Notification) {
        if let panel = notification.object as? NSWindow {
            Self.hideStandardWindowButtons(in: panel)
        }
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

    private func applyModelFrameIfNeeded() {
        guard let panel = window, let parentWindow else { return }
        let target = Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow)
        guard panel.frame != target else { return }
        applyModelFrame()
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

    private static func hideStandardWindowButtons(in panel: NSWindow) {
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = panel.standardWindowButton(buttonType) else { continue }
            button.isHidden = true
            button.alphaValue = 0
            button.isEnabled = false
        }
    }
}

/// Floating Dock controls should work on the first click even when another
/// cmux window is currently key, matching native titlebar control behavior.
private final class WorkspaceFloatingDockHostingView<Content: View>: UserSizedWindowHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
