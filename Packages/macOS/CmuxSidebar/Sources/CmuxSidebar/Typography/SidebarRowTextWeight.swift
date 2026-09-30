public import AppKit
public import SwiftUI

/// Font weights the workspace sidebar draws its row text with.
///
/// The workspace list has two renderers: the AppKit table cells and the
/// SwiftUI rows. Both resolve weight here, so a row reads the same whichever
/// one draws it, and a weight change cannot land in one path only.
///
/// Resting rows are `regular`: a sidebar where every title is semibold has no
/// spare emphasis left for the rows that matter. Selected rows and rows with
/// unread notifications keep `semibold`, so the two states still stand out
/// without the whole list shouting.
public enum SidebarRowTextWeight: Sendable, Hashable, CaseIterable {
    case regular
    case medium
    case semibold

    /// Weight for a workspace row's title.
    ///
    /// `isSelected` covers both the active workspace and a row that joined a
    /// multi-selection; both are rows the user is acting on.
    public static func workspaceTitle(isSelected: Bool, hasUnread: Bool) -> SidebarRowTextWeight {
        isSelected || hasUnread ? .semibold : .regular
    }

    /// Weight for a workspace group header's name. Constant, so the header's
    /// measured height never depends on selection.
    public static let workspaceGroupHeaderName: SidebarRowTextWeight = .medium

    public var appKitWeight: NSFont.Weight {
        switch self {
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        }
    }

    public var swiftUIWeight: Font.Weight {
        switch self {
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        }
    }
}
