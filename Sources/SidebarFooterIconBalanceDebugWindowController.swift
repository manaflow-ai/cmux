import AppKit
import CmuxAppKitSupportUI
import SwiftUI

#if DEBUG
@MainActor
final class SidebarFooterIconBalanceDebugWindowController: ReleasingWindowController {
    private weak var decorator: (any WindowDecorating)?

    init(decorator: (any WindowDecorating)?) {
        self.decorator = decorator
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.sidebarFooterIconBalance.title",
            defaultValue: "Footer Icon Balance Lab"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sidebarFooterIconBalanceDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SidebarFooterIconBalanceDebugView())
        decorator?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow(activateApplication: true)
    }
}

#endif
