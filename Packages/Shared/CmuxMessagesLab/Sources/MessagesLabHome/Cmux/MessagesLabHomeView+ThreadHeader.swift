import AppKit
import CmuxHomeCore

/// The thread header and message links of the native Home (HomeProjection+ThreadHeader.swift), and
/// their DEBUG socket drives (scripts/cmux-next/home-tree-thread-check.py).
extension MessagesLabHomeView {
    /// The build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`): "Copy Link" names messages in it.
    public var linkScheme: String? {
        get { projection.tree.linkScheme }
        set { projection.tree.linkScheme = newValue }
    }

    /// Automation (DEBUG socket), tree threads: `header` (the open thread view's header), `chip` (a click on
    /// its status chip through the click's path), `rename` {value} and `assign` {value: participant or ""}
    /// (the popover's Return and the menu's item), `copy_link` {text} (Copy Link in the menu of that
    /// bubble; answers the pasteboard). nil: not a tree action.
    public func debugTreeDrive(_ action: String, _ args: [String: String]) -> [String: String]? {
        let projection = self.projection
        func header() -> [String: String] {
            guard let root = controller.store?.state.ui.openThread, let h = projection.threadHeader(root) else { return ["header": ""] }
            return ["header": "1", "title": h.title, "status": h.status.rawValue, "owner": h.owner ?? ""]
        }
        switch action {
        case "header":
            return header()
        case "chip":
            guard let demo = controller.demo,
                  let hit = demo.threadHeaderTargets.first(where: { $0.1 == .resolve || $0.1 == .reopen }) else { return ["ok": "0"] }
            controller.clicked(CGPoint(x: hit.0.midX, y: hit.0.midY))
            return header().merging(["ok": "1"]) { a, _ in a }
        case "rename", "assign":
            guard let root = controller.store?.state.ui.openThread, let mid = projection.shownItem(root.messageId)?.messageID else { return ["ok": "0"] }
            let value = args["value"] ?? ""
            if action == "rename" {
                // Through the popover: its field takes the text, Return commits (FieldCommit).
                projection.presentRename(mid, anchor: .zero)
                projection.tree.field?.stringValue = value
                projection.tree.field.map { projection.tree.commit?.fire($0) }
            } else {
                projection.updateThread(mid, owner: value)
            }
            return ["ok": "1"]
        case "copy_link":
            guard let hit = debugBubble(text: args["text"] ?? ""),
                  let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { return ["ok": "0"] }
            controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
            guard let item = menu.items.first(where: { ($0 as? MenuAction)?.label == CmuxStrings.copyLink }),
                  let run = item.action else { return ["ok": "0", "error": "no Copy Link"] }
            NSApp.sendAction(run, to: item.target, from: item)
            return ["ok": "1", "link": NSPasteboard.general.string(forType: .string) ?? ""]
        default:
            return nil
        }
    }
}
