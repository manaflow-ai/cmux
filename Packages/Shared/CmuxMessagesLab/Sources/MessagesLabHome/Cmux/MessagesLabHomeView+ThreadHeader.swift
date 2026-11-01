import AppKit
import CmuxHomeCore

/// The message links of the native Home (HomeProjection+ThreadHeader.swift), and their DEBUG socket drives
/// (scripts/cmux-next/home-tree-thread-check.py).
extension MessagesLabHomeView {
    /// The build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`): "Copy Link" names messages in it.
    public var linkScheme: String? {
        get { projection.tree.linkScheme }
        set { projection.tree.linkScheme = newValue }
    }

    /// Automation (DEBUG socket), tree threads: `header` (`open`: a thread view is open; `header`: it draws anything above its root;
    /// Messages draws nothing, https://github.com/manaflow-ai/cmux/issues/26686) and `copy_link` {text} (Copy Link
    /// in the menu of that bubble; answers the pasteboard). nil: not a tree action.
    public func debugTreeDrive(_ action: String, _ args: [String: String]) -> [String: String]? {
        switch action {
        case "header":
            return ["open": controller.demo?.threadOpen == true ? "1" : "", "header": controller.demo?.threadHeaderFrame == nil ? "" : "1"]
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
