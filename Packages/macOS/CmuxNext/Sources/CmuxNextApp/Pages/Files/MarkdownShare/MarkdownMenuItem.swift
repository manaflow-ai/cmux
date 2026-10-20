import AppKit

/// A menu item that runs a closure: the Markdown Share menu's entries, which act on one tab's file
/// and are not app actions of their own.
final class MarkdownMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() { run() }
}
