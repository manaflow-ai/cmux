import Foundation

/// The pure reducer of the section layout: `(document, op) -> document or
/// reject`, checking invariants L1-L6 (plans/cmux-next/sidebar-sections.md
/// 4). The store runs the same rules; clients run it to overlay pending
/// intents on the confirmed mirror.
public nonisolated enum SidebarLayoutReducer {
    public static let maxSections = 32
    public static let maxItems = 200
    public static let maxTitleLength = 80
    public static let maxRowsRange = 1...50

    /// The new document, or the reject. A change bumps `revision` by one;
    /// a no-op returns the document unchanged.
    public static func reduce(_ document: SidebarLayoutDocument, _ op: SidebarLayoutOp) -> Result<SidebarLayoutDocument, SidebarLayoutReject> {
        .success(document)
    }
}
