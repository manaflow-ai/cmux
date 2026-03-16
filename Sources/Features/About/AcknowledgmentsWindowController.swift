//
//  AcknowledgmentsWindowController.swift
//  cmux
//
//  Created by Gale Williams on 3/16/26.
//

import AppKit
import SwiftUI

// MARK: - AcknowledgmentsWindowController

final class AcknowledgmentsWindowController: NSWindowController, NSWindowDelegate {
    // MARK: Static Properties

    static let shared = AcknowledgmentsWindowController()

    // MARK: Lifecycle

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "about.licenses.windowTitle", defaultValue: "Third-Party Licenses")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.licenses")
        window.center()
        window.contentView = NSHostingView(rootView: AcknowledgmentsView())
        super.init(window: window)
        window.delegate = self
    }

    // MARK: Functions

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }
}
