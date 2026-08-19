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
enum SidebarTextWeight {
    /// Workspace title with no unread activity.
    static let restingTitle = NSFont.Weight.medium
    static let restingTitleSwiftUI = Font.Weight.medium

    /// Workspace title while the row has unread activity, so weight is a
    /// read/unread signal rather than a constant.
    static let unreadTitle = NSFont.Weight.semibold
    static let unreadTitleSwiftUI = Font.Weight.semibold

    /// Group/folder header names.
    static let groupName = NSFont.Weight.semibold
    static let groupNameSwiftUI = Font.Weight.semibold

    /// Inline affordances and suffixes ("Show more", compact status,
    /// checklist counts, PR status words).
    static let affordance = NSFont.Weight.regular
    static let affordanceSwiftUI = Font.Weight.regular

    static func title(hasUnread: Bool) -> NSFont.Weight {
        hasUnread ? unreadTitle : restingTitle
    }

    static func titleSwiftUI(hasUnread: Bool) -> Font.Weight {
        hasUnread ? unreadTitleSwiftUI : restingTitleSwiftUI
    }
}
