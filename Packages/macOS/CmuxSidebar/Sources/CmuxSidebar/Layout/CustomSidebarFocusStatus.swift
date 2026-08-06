public import Foundation

/// The outcome a web-backed custom sidebar is told about a workspace-focus request.
///
/// The page asks for a workspace by id and gets one of exactly three answers. They are distinct
/// because a sidebar renders them differently: a focused workspace needs no feedback, a workspace
/// that is gone should be dropped from the page's own list, and an unavailable host is a transient
/// condition worth retrying rather than a reason to forget the row.
public enum CustomSidebarFocusStatus: String, Equatable, Sendable {
    /// The workspace was found and selected, and its window was brought forward.
    case focused
    /// No workspace with that id exists in the resolved window.
    case notFound = "not-found"
    /// No window could be resolved to act on, so nothing was attempted.
    case unavailable

    /// The reply body handed back to the page's `postMessage` promise.
    ///
    /// Versioned the same way the request is, so a page written against `v: 1` can tell a future
    /// reply shape apart from this one without guessing from the keys present.
    public var replyBody: [String: Any] {
        ["v": CustomSidebarFocusStatus.protocolVersion, "status": rawValue]
    }

    /// The only protocol version this bridge speaks, on both the request and the reply.
    public static let protocolVersion = 1
}
