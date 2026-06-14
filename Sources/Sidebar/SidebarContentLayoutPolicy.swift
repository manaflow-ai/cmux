import CoreGraphics

enum SidebarContentLayoutPolicy {
    static func mode(
        position: SidebarPositionOption,
        usesWithinWindowOverlay: Bool
    ) -> SidebarContentLayoutMode {
        switch position {
        case .left:
            return usesWithinWindowOverlay ? .leftOverlay : .leftStack
        case .right:
            // Right-positioned workspace sidebar stays in stack layout even when
            // within-window material is enabled. The app can already host the
            // tool sidebar on the trailing edge, and a single stacked trailing
            // geometry keeps both sidebar dividers deterministic.
            return .rightStack
        case .top:
            return .topStack
        case .bottom:
            return .bottomStack
        }
    }

    static func rightSidebarAvailableWidth(
        totalWidth: CGFloat,
        workspaceSidebarWidth: CGFloat,
        position: SidebarPositionOption,
        isWorkspaceSidebarVisible: Bool
    ) -> CGFloat {
        let sanitizedTotalWidth = max(0, totalWidth)
        guard isWorkspaceSidebarVisible, position == .right else {
            return sanitizedTotalWidth
        }
        return max(0, sanitizedTotalWidth - max(0, workspaceSidebarWidth))
    }
}
