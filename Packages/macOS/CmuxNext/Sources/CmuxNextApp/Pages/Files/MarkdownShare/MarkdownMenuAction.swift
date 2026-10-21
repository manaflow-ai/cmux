import AppKit

/// The target of a Markdown Share menu entry: runs a closure. The entries act on one tab's file and
/// are not app actions of their own. The item keeps its target alive through `representedObject`.
final class MarkdownMenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func runAction() { run() }

    /// A menu item titled `title` that runs `run`.
    static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let action = MarkdownMenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(runAction), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}
