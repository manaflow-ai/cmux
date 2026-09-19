import AppKit
import CmuxFoundation
import SwiftUI

final class AcknowledgmentsWindowController: ReleasingWindowController {
    override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "about.licenses", defaultValue: "Licenses")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.licenses")
        window.center()
        window.contentView = NSHostingView(rootView: AcknowledgmentsView())
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow(centerWhenHidden: false)
    }
}

