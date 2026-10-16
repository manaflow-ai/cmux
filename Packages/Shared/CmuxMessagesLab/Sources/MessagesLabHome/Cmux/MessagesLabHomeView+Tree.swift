import AppKit
import CmuxHomeCore

/// Message links and the open branch of a nested thread (HomeProjection+Tree.swift), for the
/// docked Home's hand-off and the DEBUG socket.
extension MessagesLabHomeView {
    /// Opens the message a permalink names (`#/conversation/<c>/message/<m>`): its thread at its
    /// own branch, at any depth, once the shown window holds it.
    public func reveal(message: String) { projection.reveal(MessageID(message)) }

    /// The owner's id of the message the open thread view shows (the drilled branch's message,
    /// else the root): the message part of a hand-off to Channels. nil with no thread open.
    public var openThreadMessage: String? { projection.openThreadMessage?.rawValue }

    /// Automation (DEBUG socket): the open drill path, root first, as owner ids ("" for a
    /// message with no owner id yet).
    public var debugOpenThreadPath: [String] { projection.openThreadPath.map { $0?.rawValue ?? "" } }

    /// Automation (DEBUG socket): a click on the "N Replies" label under the message `text` in
    /// the open thread view, through the click's path (`ChatController.clicked`, whose first
    /// stop is `hostControl(at:)`). The open drill path after it (`debugOpenThreadPath`), nil when
    /// no such label shows.
    public func debugOpenBranch(text: String) -> [String]? {
        guard let demo = controller.demo, let store = controller.store,
              let target = store.state.conversation.messages.first(where: { Self.text(of: $0) == text })?.id else { return nil }
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 3) {
            for x in stride(from: b.minX, to: b.maxX, by: 3) {
                let p = CGPoint(x: x, y: y)
                guard case let .dispatch(.openThreadPath(path))? = demo.hostControl(at: p), path.last?.messageId == target else { continue }
                controller.clicked(p)
                return debugOpenThreadPath
            }
        }
        return nil
    }

    /// Automation (DEBUG socket): Reply… in the context menu of the shown bubble whose text is
    /// `text` (the thread view's when one is open), built and chosen by the right-click's path.
    /// The open drill path after it, nil when no such bubble shows.
    public func debugReply(text: String) -> [String]? {
        guard let demo = controller.demo else { return nil }
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 3) {
            for x in stride(from: b.minX, to: b.maxX, by: 3) {
                let p = CGPoint(x: x, y: y)
                guard let hit = demo.hit(p), case let .text(shown, _) = hit.row.part, shown == text,
                      let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { continue }
                controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
                guard let item = menu.items.first(where: { ($0 as? MenuAction)?.label == Strings.menuReplyEllipsis }),
                      let action = item.action else { return nil }
                NSApp.sendAction(action, to: item.target, from: item)
                return debugOpenThreadPath
            }
        }
        return nil
    }

    private static func text(of m: Message) -> String {
        m.parts.compactMap(\.plainText).joined(separator: "\n")
    }
}
