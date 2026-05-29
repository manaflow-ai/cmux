import CoreGraphics

enum WindowChromeMetrics {
    static let sharedChromeBarHeight: CGFloat = 28
    static let appTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let bonsplitTabBarHeight: CGFloat = sharedChromeBarHeight
    static let secondaryTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let minimumTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let maximumTitlebarHeight: CGFloat = 72
    static let defaultTitlebarHeight: CGFloat = sharedChromeBarHeight

    static func clampedTitlebarHeight(_ height: CGFloat) -> CGFloat {
        max(minimumTitlebarHeight, min(maximumTitlebarHeight, height))
    }
}

enum MinimalModeChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
}

enum HeaderChromeControlMetrics {
    static let buttonSize: CGFloat = 20
    static let iconSize: CGFloat = 12
    static let iconFrameSize: CGFloat = 14
    static let cornerRadius: CGFloat = 6

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        max(Self.iconFrameSize, iconSize + 2)
    }
}

enum RightSidebarChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
    static let secondaryBarHeight: CGFloat = WindowChromeMetrics.secondaryTitlebarHeight
    static let barHorizontalPadding: CGFloat = 8
    static let barVerticalPadding: CGFloat = 4
    static let controlHeight: CGFloat = secondaryBarHeight - (barVerticalPadding * 2)
    static let controlHorizontalPadding: CGFloat = 8
    static let controlCornerRadius: CGFloat = 5
    static let headerControlSize: CGFloat = HeaderChromeControlMetrics.buttonSize
    static let headerIconSize: CGFloat = 10
    static let headerIconFrameSize: CGFloat = headerIconSize
    static let headerControlSpacing: CGFloat = 4
    static let headerControlCornerRadius: CGFloat = HeaderChromeControlMetrics.cornerRadius
    static let headerControlCenterAlignmentAdjustment: CGFloat = 0
}

enum SidebarWorkspaceListMetrics {
    static let firstRowTopOffset: CGFloat = MinimalModeChromeMetrics.titlebarHeight + 2
    static let rowVerticalPadding: CGFloat = 8
    static let topScrimHeight: CGFloat = firstRowTopOffset + 20
    static let bottomScrimHeight: CGFloat = topScrimHeight

    static var scrollTopInset: CGFloat {
        max(0, firstRowTopOffset - rowVerticalPadding)
    }
}

struct SidebarWorkspaceScrollInsets: Equatable {
    static let workspaceList = SidebarWorkspaceScrollInsets(
        top: SidebarWorkspaceListMetrics.scrollTopInset,
        bottom: SidebarWorkspaceListMetrics.bottomScrimHeight
    )

    let top: CGFloat
    let bottom: CGFloat

    nonisolated var total: CGFloat {
        top + bottom
    }
}

enum SidebarWorkspaceScrollLayout {
    nonisolated static func contentMinHeight(
        viewportHeight: CGFloat,
        insets: SidebarWorkspaceScrollInsets
    ) -> CGFloat {
        return max(0, viewportHeight - insets.total)
    }

    nonisolated static func emptyAreaHeight(
        contentMinHeight: CGFloat,
        rowsHeight: CGFloat?,
        rowsLayoutCompleteness: SidebarWorkspaceRowsLayoutCompleteness = .complete
    ) -> CGFloat {
        switch rowsLayoutCompleteness {
        case .empty:
            return max(0, contentMinHeight - max(0, rowsHeight ?? 0))
        case .unmeasured, .partial:
            return 0
        case .complete:
            guard let rowsHeight, rowsHeight > 0 else { return 0 }
            return max(0, contentMinHeight - rowsHeight)
        }
    }

    nonisolated static func contentOverflows(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        tolerance: CGFloat = 1
    ) -> Bool {
        contentHeight > viewportHeight + tolerance
    }

    nonisolated static func rowsOverflow(
        rowsHeight: CGFloat?,
        contentMinHeight: CGFloat,
        rowsLayoutCompleteness: SidebarWorkspaceRowsLayoutCompleteness = .complete,
        tolerance: CGFloat = 1
    ) -> Bool {
        switch rowsLayoutCompleteness {
        case .empty:
            return false
        case .unmeasured:
            return false
        case .partial:
            return true
        case .complete:
            break
        }
        guard let rowsHeight else { return false }
        guard rowsHeight > 0 else { return true }
        return contentOverflows(
            contentHeight: rowsHeight,
            viewportHeight: contentMinHeight,
            tolerance: tolerance
        )
    }

    nonisolated static func rowsLayoutCompleteness<ID: Hashable>(
        laidOutRowIds: Set<ID>,
        workspaceIds: [ID]
    ) -> SidebarWorkspaceRowsLayoutCompleteness {
        guard !workspaceIds.isEmpty else { return .empty }
        guard !laidOutRowIds.isEmpty else { return .unmeasured }
        return laidOutRowIds.isSuperset(of: workspaceIds) ? .complete : .partial
    }
}

enum SidebarWorkspaceRowsLayoutCompleteness: Equatable {
    case empty
    case unmeasured
    case partial
    case complete
}

struct SidebarWorkspaceRowsMeasurement<ID: Equatable>: Equatable {
    let workspaceIds: [ID]
    let rowsHeight: CGFloat

    nonisolated func rowsHeight(for currentWorkspaceIds: [ID]) -> CGFloat? {
        guard workspaceIds == currentWorkspaceIds else { return nil }
        return max(0, rowsHeight)
    }

    nonisolated func isEquivalent(
        to other: SidebarWorkspaceRowsMeasurement<ID>,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        workspaceIds == other.workspaceIds && abs(rowsHeight - other.rowsHeight) <= tolerance
    }
}
