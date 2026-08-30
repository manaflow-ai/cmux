import AppKit
import SwiftUI

/// Weight roles for text in the workspace sidebar.
///
/// Weight is reserved for identity and state: titles rest at `.medium` and
/// rise to `.semibold` only while the row has unread activity, group names
/// keep `.semibold` as the one structural anchor, and inline affordances
/// stay `.regular` so they never outweigh the content they gate. Both
/// sidebar engines (the AppKit list and the legacy `TabItemView` path)
/// must read from here so the flag flip cannot fork typography.
///
/// Constructed at the point of use (`SidebarTypography()`), like
/// `SidebarWorkspaceGroupHeaderMetrics` and `SidebarAppearanceColorResolver`;
/// the memberwise defaults are the production values, and tests can construct
/// variants to exercise the selection logic.
struct SidebarTypography: Equatable {
    /// Workspace title with no unread activity.
    var restingTitle: NSFont.Weight = .medium
    /// Workspace title with no unread activity (legacy SwiftUI engine).
    var restingTitleSwiftUI: Font.Weight = .medium

    /// Workspace title while the row has unread activity, so weight is a
    /// read/unread signal rather than a constant.
    var unreadTitle: NSFont.Weight = .semibold
    /// Unread-title weight for the legacy SwiftUI engine.
    var unreadTitleSwiftUI: Font.Weight = .semibold

    /// Group/folder header names.
    var groupName: NSFont.Weight = .semibold
    /// Group/folder header names (legacy SwiftUI engine).
    var groupNameSwiftUI: Font.Weight = .semibold

    /// Inline affordances and suffixes ("Show more", compact status,
    /// checklist counts, PR status words).
    var affordance: NSFont.Weight = .regular
    /// Affordance weight for the legacy SwiftUI engine.
    var affordanceSwiftUI: Font.Weight = .regular

    /// Resolves a workspace title's weight from its unread state.
    func title(hasUnread: Bool) -> NSFont.Weight {
        hasUnread ? unreadTitle : restingTitle
    }

    /// Resolves a workspace title's weight from its unread state
    /// (legacy SwiftUI engine).
    func titleSwiftUI(hasUnread: Bool) -> Font.Weight {
        hasUnread ? unreadTitleSwiftUI : restingTitleSwiftUI
    }
}
