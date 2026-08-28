public import Foundation

/// A counter that forces a hosted web sidebar to re-fetch its page.
///
/// A web sidebar reloads only when its source *value* changes, because `updateNSView` runs on every
/// unrelated SwiftUI invalidation and reloading unconditionally would discard scroll position and
/// form state about once a second. That is right for redraws and wrong for `cmux sidebar reload`,
/// where the source is identical by construction — the user edited the page behind the same path or
/// restarted the server behind the same URL — and reloading is the entire request.
///
/// So the token is the second half of the load condition: the host bumps it when a reload is
/// actually asked for, and an unchanged source with a bumped token still reloads. Counting rather
/// than flagging means a token that arrives while an earlier one is still settling is not lost.
public struct CustomSidebarWebReloadToken: Equatable, Sendable {
    /// The number of reloads requested so far. Equal values mean no reload is pending.
    public let revision: Int

    /// A token that has never requested a reload.
    public static let initial = CustomSidebarWebReloadToken(revision: 0)

    /// Creates a token at an explicit revision.
    ///
    /// - Parameter revision: The reload count.
    public init(revision: Int) {
        self.revision = revision
    }

    /// The token one reload later.
    public func bumped() -> CustomSidebarWebReloadToken {
        CustomSidebarWebReloadToken(revision: revision + 1)
    }
}
