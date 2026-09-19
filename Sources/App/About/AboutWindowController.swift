import AppKit
import CmuxFoundation
import SwiftUI

final class AboutWindowController: ReleasingWindowController {
    private let acknowledgments: AcknowledgmentsWindowController
    private let prepareWindow: (NSWindow) -> Void
    private let prepareTitlebar: (NSWindow) -> Void

    init(
        acknowledgments: AcknowledgmentsWindowController,
        prepareWindow: @escaping (NSWindow) -> Void,
        prepareTitlebar: @escaping (NSWindow) -> Void
    ) {
        self.acknowledgments = acknowledgments
        self.prepareWindow = prepareWindow
        self.prepareTitlebar = prepareTitlebar
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        window.center()
        window.contentView = NSHostingView(rootView: AboutPanelView(showLicenses: { [acknowledgments] in acknowledgments.show() }))
        prepareTitlebar(window)
        prepareWindow(window)
        return window
    }

    func show() {
        let window = managedWindow()
        prepareTitlebar(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

