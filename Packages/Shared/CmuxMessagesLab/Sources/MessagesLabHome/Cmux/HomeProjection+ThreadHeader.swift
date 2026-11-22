import AppKit
import CmuxHomeCore

/// The tree thread view's state: a permalink being revealed and each message's link ("Copy Link", the daemon's
/// permalink form). The thread view has no header (https://github.com/manaflow-ai/cmux/issues/26686): as in
/// Messages, the root bubble is its first row.
final class HomeTreeState {
    /// The owner's answer for the permalink waiting in `pendingReveal` (nil: none yet or no resolver).
    var target: HomeLinkTarget?
    /// An older page asked for a permalink is in flight; pages asked so far (a bound without a resolver).
    var paging = false
    var pages = 0
    /// The build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`); nil: no Copy Link.
    var linkScheme: String?
}

extension HomeProjection {
    /// The message's permalink in the build's scheme (the daemon's form, conversation-link-resolve).
    func messageLink(_ id: ID) -> String? {
        guard let scheme = tree.linkScheme, let owner = ownerID(id) else { return nil }
        return "\(scheme)://conversation/\(conversation.rawValue)/message/\(owner.rawValue)"
    }
}
