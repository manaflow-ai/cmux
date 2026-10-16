#if DEBUG
import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextSettings

/// DEBUG ONLY: nested threads in the native Home (MessagesLab `ThreadMode.tree`), for
/// scripts/cmux-next/home-tree-thread-check.py.
extension DebugHome {
    /// `debug.home.drive {action: permalink, url}`: opens a message link the way the docked Home's
    /// hand-off does (`HomeDockView.open`, `TopHomePageView.show(_:message:)`): classic Home's page,
    /// else the dock. `url`: `#/conversation/<c>[/message/<m>]` (the page route) or
    /// `<scheme>://conversation/<c>[/message/<m>]`.
    static func drivePermalink(_ params: [String: CmuxNextSettings.JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        guard let selection = selection(fromLink: params["url"]?.stringValue ?? "") else {
            return .object(["error": .string("url must be #/conversation/<id>[/message/<id>]")])
        }
        if services.home.dock.isClassic {
            guard let page = services.windows.active?.topPages.views[.home] as? TopHomePageView else {
                return .object(["error": .string("classic Home is not shown")])
            }
            page.show(ConversationID(selection.conversation), message: selection.message)
        } else {
            guard let dock = HomeDockTab.view(services) else { return .object(["error": .string("no docked Home")]) }
            dock.open(selection)
        }
        return .object(["ok": .bool(true), "conversation": .string(selection.conversation),
                        "message": selection.message.map { .string($0) } ?? .null])
    }

    /// `ok`, the open thread's root (transcript id), the drill path of the shown transcript (owner ids,
    /// root first) and the owner id of the message the thread view shows.
    static func treeReply(_ view: HomeNativeTranscriptView, ok: Bool) -> CmuxNextSettings.JSONValue {
        .object(["ok": .bool(ok),
         "open_thread": view.openThreadRoot.map { .string($0) } ?? .null,
         "thread_path": .array(view.debugOpenThreadPath.map { .string($0) }),
         "thread_message": view.openThreadMessage.map { .string($0) } ?? .null])
    }

    private static func selection(fromLink link: String) -> HomeDockSelection? {
        var rest = Substring(link)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] } else {
            while rest.first == "#" || rest.first == "/" { rest = rest.dropFirst() }
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 4, parts[0] == "conversation", HomeDockSelection.isLinkID(parts[1]) else { return nil }
        guard parts.count == 4 else { return HomeDockSelection(conversation: parts[1]) }
        guard parts[2] == "message", HomeDockSelection.isLinkID(parts[3]) else { return nil }
        return HomeDockSelection(conversation: parts[1], message: parts[3])
    }
}
#endif
