import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Closure menu item

/// NSMenuItem driven by a closure (the lanes menu has no long-lived target).
@MainActor
final class SidebarRowClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(execute), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func execute() {
        handler()
    }
}
