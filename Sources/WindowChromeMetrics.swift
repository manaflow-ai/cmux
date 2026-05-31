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

enum TitlebarFolderTitleLayout {
    /// Horizontal gap between the sidebar's trailing edge and the folder icon/title
    /// when the sidebar is open.
    static let openSidebarGap: CGFloat = 12
    /// Leading inset for the folder icon/title in non-native fullscreen when the
    /// sidebar is collapsed (the inline fullscreen controls precede it).
    static let fullscreenCollapsedInset: CGFloat = 8
    /// Width slop used to treat a sidebar width as "at minimum" (the live width can
    /// settle a hair above the clamp after a resize).
    static let minimumWidthTolerance: CGFloat = 0.5

    /// Leading inset for the custom titlebar's folder icon + workspace title.
    ///
    /// When the sidebar sits at its minimum width, the folder icon/title keeps the
    /// same x-position whether the sidebar is open or collapsed, so toggling the
    /// sidebar does not shift it. Above the minimum width, collapsing the sidebar
    /// slides the title back to `collapsedInset` (the traffic-light + sidebar-control
    /// inset); that movement is intentional so a wide sidebar does not leave a large
    /// gap on the left.
    ///
    /// - Parameters:
    ///   - isFullScreen: Whether the window is in non-native fullscreen.
    ///   - sidebarVisible: Whether the left sidebar is currently shown.
    ///   - sidebarWidth: The current (or last persisted) sidebar width.
    ///   - minimumSidebarWidth: The configured minimum sidebar width.
    ///   - collapsedInset: The leading inset used when the sidebar is collapsed and
    ///     wider than the minimum (just past the traffic lights and sidebar controls).
    /// - Returns: The leading padding for the folder icon/title HStack.
    static func leadingInset(
        isFullScreen: Bool,
        sidebarVisible: Bool,
        sidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        collapsedInset: CGFloat
    ) -> CGFloat {
        if isFullScreen && !sidebarVisible {
            return fullscreenCollapsedInset
        }
        let openInset = sidebarWidth + openSidebarGap
        if sidebarVisible {
            return openInset
        }
        // Collapsed. At the minimum width, keep the folder icon/title where it sits
        // when the sidebar is open so toggling the sidebar does not move it. Above the
        // minimum, slide back to the traffic-light inset.
        if sidebarWidth <= minimumSidebarWidth + minimumWidthTolerance {
            return openInset
        }
        return collapsedInset
    }
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
        max(0, viewportHeight - insets.total)
    }
}
