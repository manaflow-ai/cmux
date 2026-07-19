import AppKit
import SwiftUI

/// Floating utility panel hosting the share-session chat. Nonactivating so
/// opening or clicking it never steals focus from the terminal; closing the
/// panel only hides it (stopping the session goes through the Stop button or
/// the command palette).
@MainActor
final class ShareChatWindowController: NSObject {
    private let panel: NSPanel
    private var didPositionOnce = false

    init(controller: ShareSessionController) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = String(localized: "share.chat.title", defaultValue: "Share Session")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 280, height: 340)
        panel.contentView = NSHostingView(rootView: ShareChatView(controller: controller))
    }

    func show() {
        if !didPositionOnce {
            didPositionOnce = true
            positionBottomTrailingOfMainWindow()
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    private func positionBottomTrailingOfMainWindow() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else {
            panel.center()
            return
        }
        let margin: CGFloat = 24
        panel.setFrameOrigin(NSPoint(
            x: window.frame.maxX - panel.frame.width - margin,
            y: window.frame.minY + margin
        ))
    }
}
