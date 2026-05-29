import AppKit
import ExtensionKit
import Foundation

@available(macOS 13.0, *)
@MainActor
public enum CMUXSidebarExtensionBrowserPresenter {
    public static func present(from anchorView: NSView, title: String) {
        let browserViewController = EXAppExtensionBrowserViewController()
        browserViewController.title = title

        let browserPanel = SidebarExtensionBrowserPanel(contentViewController: browserViewController)
        browserPanel.title = title
        browserPanel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        browserPanel.contentMinSize = NSSize(width: 560, height: 460)
        browserPanel.setContentSize(NSSize(width: 760, height: 600))
        browserPanel.isFloatingPanel = true
        browserPanel.hidesOnDeactivate = false
        browserPanel.isReleasedWhenClosed = false

        if let parentWindow = anchorView.window {
            browserPanel.setFrameOrigin(Self.panelOrigin(anchorView: anchorView, parentWindow: parentWindow, panel: browserPanel))
        } else {
            browserPanel.center()
        }
        BrowserPanelController.shared.show(panel: browserPanel)
    }

    private static func panelOrigin(anchorView: NSView, parentWindow: NSWindow, panel: NSPanel) -> NSPoint {
        let anchorFrame = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrameInScreen = parentWindow.convertToScreen(anchorFrame)
        let visibleFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let proposedX = anchorFrameInScreen.minX
        let proposedY = anchorFrameInScreen.minY - panel.frame.height - 8
        let x = min(max(proposedX, visibleFrame.minX + 12), visibleFrame.maxX - panel.frame.width - 12)
        let y = min(max(proposedY, visibleFrame.minY + 12), visibleFrame.maxY - panel.frame.height - 12)
        return NSPoint(x: x, y: y)
    }
}

@available(macOS 13.0, *)
@MainActor
private final class SidebarExtensionBrowserPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@available(macOS 13.0, *)
@MainActor
private final class BrowserPanelController: NSObject, NSWindowDelegate {
    static let shared = BrowserPanelController()

    private var panel: NSPanel?

    func show(panel: NSPanel) {
        if let existingPanel = self.panel {
            existingPanel.close()
        }
        self.panel = panel
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        self.panel = nil
    }
}
