#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import SwiftUI
import UIKit

/// One swipe action (Mail style: tinted, icon over a short label). Tints
/// come from `FeedSwipeTint`, which reads well in light and dark mode.
struct FeedSwipeAction: Identifiable {
    var id: String
    var title: String
    var systemImage: String
    var tint: Color
    /// The action removes the row (Done): it runs while the row is slid out; others run after it slides back.
    var removesRow = false
    var action: () -> Void
}

/// Swipe action fills: UIKit's semantic system colors (the ones Mail and
/// Messages use), which adapt to light and dark mode. White labels stay
/// legible on every one of them in both modes.
enum FeedSwipeTint {
    /// Destructive (Deny, Decline): the system destructive red.
    static var destructive: Color { Color(uiColor: .systemRed) }
    /// Archive-like (Done), as Mail's Archive.
    static var archive: Color { Color(uiColor: .systemPurple) }
    /// Read state, as Mail's Unread.
    static var read: Color { Color(uiColor: .systemBlue) }
    /// Approve (Allow).
    static var approve: Color { Color(uiColor: .systemGreen) }
}

/// Which row's actions are showing, so opening one closes the other and a
/// scroll closes them all (owned by the Feed screen).
@MainActor
@Observable
final class FeedSwipeCoordinator {
    var openID: String?
    /// Demo driver requests: reveal the actions, or perform an action as a full swipe.
    var demoReveal: String?
    var demoPerform: (id: String, action: String)?
    var demoSerial = 0
}

extension FeedItem {
    /// Mail-style trailing actions for this event, outermost (full swipe)
    /// first. At most three: the decision the event asks for, then read state
    /// or Open. Everything else is in the cell's context menu.
    @MainActor
    func swipeActions(store: FeedStore, open: @escaping () -> Void) -> [FeedSwipeAction] {
        let read = isRead
            ? FeedSwipeAction(id: "unread", title: "Unread", systemImage: "envelope.badge", tint: FeedSwipeTint.read) { store.markUnread(id) }
            : FeedSwipeAction(id: "read", title: "Read", systemImage: "envelope.open", tint: FeedSwipeTint.read) { store.markRead(id) }
        let done = FeedSwipeAction(id: "done", title: "Done", systemImage: "checkmark", tint: FeedSwipeTint.archive, removesRow: true) {
            withAnimation(.cmuxMobileSmooth) { store.markDone(id) }
        }
        guard resolution == nil else { return [done, read] }
        switch kind {
        case .permission(let request):
            // A full swipe denies, never allows: granting a permission takes a deliberate tap.
            let allow = request.phoneOptions.first(where: { $0.kind == .allowOnce }) ?? request.phoneOptions.first(where: \.isAllow)
            let deny = request.phoneOptions.first(where: { $0.kind == .rejectOnce }) ?? request.phoneOptions.first(where: { !$0.isAllow })
            var actions: [FeedSwipeAction] = []
            if let deny {
                actions.append(FeedSwipeAction(id: "deny", title: "Deny", systemImage: "xmark.shield", tint: FeedSwipeTint.destructive) {
                    withAnimation(.cmuxMobileSmooth) { store.respond(id, option: deny) }
                })
            }
            if let allow {
                // The allow asks for Face ID before it is sent (verify/phone-approvals.md).
                actions.append(FeedSwipeAction(id: "allow", title: "Allow", systemImage: "faceid", tint: FeedSwipeTint.approve) {
                    withAnimation(.cmuxMobileSmooth) { store.respond(id, option: allow) }
                })
            }
            return actions
        case .question(let question) where question.isPending:
            let answer = FeedSwipeAction(id: "answer", title: "Answer", systemImage: "arrowshape.turn.up.left", tint: FeedSwipeTint.read, action: open)
            let decline = FeedSwipeAction(id: "decline", title: "Decline", systemImage: "xmark", tint: FeedSwipeTint.destructive) {
                withAnimation(.cmuxMobileSmooth) { store.decline(id) }
            }
            return [decline, answer]
        case .needsInput:
            // Answered in the terminal: the decision is opening it.
            let answer = FeedSwipeAction(id: "answer", title: "Open", systemImage: "terminal", tint: FeedSwipeTint.read, action: open)
            return [done, answer]
        default:
            return [done, read]
        }
    }
}
#endif
