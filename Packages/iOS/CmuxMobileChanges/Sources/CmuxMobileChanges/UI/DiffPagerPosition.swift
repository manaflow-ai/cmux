/// Pure page-position text logic for the diff pager pill.
public struct DiffPagerPosition: Sendable, Equatable {
    /// Zero-based selected page.
    public let selectedIndex: Int
    /// Total page count.
    public let pageCount: Int

    /// Creates a page position, clamping invalid values for display.
    /// - Parameters:
    ///   - selectedIndex: Zero-based selected page.
    ///   - pageCount: Total number of pages.
    public init(selectedIndex: Int, pageCount: Int) {
        self.selectedIndex = selectedIndex
        self.pageCount = pageCount
    }

    /// One-based current page, or zero when there are no pages.
    public var currentPage: Int {
        guard pageCount > 0 else { return 0 }
        return min(max(selectedIndex, 0), pageCount - 1) + 1
    }

    /// Localized `k / n` pill text.
    public var localizedText: String {
        String(
            format: String(
                localized: "changes.pager.position",
                defaultValue: "%1$lld / %2$lld",
                bundle: .module
            ),
            Int64(currentPage),
            Int64(max(0, pageCount))
        )
    }
}
