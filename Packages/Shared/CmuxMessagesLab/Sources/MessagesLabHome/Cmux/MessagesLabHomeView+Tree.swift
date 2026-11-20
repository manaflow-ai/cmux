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
              let target = store.state.conversation.messages.first(where: { Self.text(of: $0) == text })?.id,
              let bubble = debugBubble(text: text) else { return nil }
        // The label sits under the bubble: a small strip, not the whole view (the socket gives a drive 2 s).
        let b = controller.host.bounds
        for y in stride(from: bubble.body.maxY, to: min(b.maxY, bubble.body.maxY + 240), by: 3) {
            for x in stride(from: b.minX, to: b.maxX, by: 8) {
                let p = CGPoint(x: x, y: y)
                guard case let .dispatch(.openThreadPath(path))? = demo.hostControl(at: p), path.last?.messageId == target else { continue }
                controller.clicked(p)
                return debugOpenThreadPath
            }
        }
        return nil
    }

    /// Reply to Selection from the keyboard or the palette (`home.replyToSelection`): the selected
    /// text of one message is the reply's quote. False when there is no such selection.
    public func replyToSelection() -> Bool {
        guard controller.intents?.canReply == true, let quote = controller.selectionQuote(),
              controller.intents?.canInteract(with: quote.source.messageId) != false else { return false }
        controller.replyToSelection(quote)
        return true
    }

    /// Automation (DEBUG socket): Reply… in the context menu of the shown bubble whose text is
    /// `text` (the thread view's when one is open), built and chosen by the right-click's path.
    /// The open drill path after it, nil when no such bubble shows.
    public func debugReply(text: String) -> [String]? {
        guard let hit = debugBubble(text: text), let menu = controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY)) else { return nil }
        controller.menuHighlight?.discard(); controller.menuHighlight = nil // never shown
        guard let item = menu.items.first(where: { ($0 as? MenuAction)?.label == Strings.menuReplyEllipsis }),
              let action = item.action else { return nil }
        NSApp.sendAction(action, to: item.target, from: item)
        return debugOpenThreadPath
    }

    /// Automation (DEBUG socket): the shown bubble whose text is `text` (the thread view's when one is
    /// open), found on a coarse grid (a bubble is at least 30 pt tall and 30 pt wide).
    func debugBubble(text: String) -> MessagesWindowView.Hit? {
        guard let demo = controller.demo else { return nil }
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 6) {
            for x in stride(from: b.minX, to: b.maxX, by: 12) {
                if let hit = demo.hit(CGPoint(x: x, y: y)), case let .text(shown, _) = hit.row.part, shown == text { return hit }
            }
        }
        return nil
    }

    private static func text(of m: Message) -> String {
        m.parts.compactMap(\.plainText).joined(separator: "\n")
    }
}
