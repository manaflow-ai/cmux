import Foundation

/// Reasons `link.open` and the Copy Link actions refuse (cmux:// deep
/// links). The link text is a format argument, never translated.
nonisolated extension RefusalStrings {
    /// A URL that is not a link in this build's scheme (another scheme, the
    /// sign-in callback, an unknown kind or a malformed id).
    static func linkNotRecognized(_ url: String) -> String {
        format("handlers.refusal.linkNotRecognized", "not a link this build of cmux opens: %@", url)
    }

    /// The link's target is closed, deleted, or on a machine that is not connected.
    static var linkTargetGone: String {
        text("handlers.refusal.linkTargetGone", "the linked item is gone: it was closed or deleted, or its machine isn't connected")
    }

    /// A nightly pane or tab link: its workspace opened, the item itself has no counterpart here.
    static var linkItemNotFound: String {
        text("handlers.refusal.linkItemNotFound", "opened the workspace, but the linked pane or tab couldn't be found")
    }

    /// Copy Link on an object its daemon gives no durable resource id.
    static var noLinkID: String {
        text("handlers.refusal.noLinkID", "this item has no link yet: cmux-tui on its machine doesn't give it a durable id")
    }
}
