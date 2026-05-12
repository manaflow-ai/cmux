import CoreGraphics

enum SidebarGeometryPolicy {
    static func workspaceSidebarResizeEdge(for position: WorkspaceSidebarPosition) -> SidebarResizeInteraction.Edge {
        switch position {
        case .left:
            return .leading
        case .right:
            return .trailing
        }
    }

    static func workspaceSidebarWidthDelta(translation: CGFloat, position: WorkspaceSidebarPosition) -> CGFloat {
        switch position {
        case .left:
            return translation
        case .right:
            return -translation
        }
    }

    static func workspaceSidebarDividerX(
        totalWidth: CGFloat,
        sidebarWidth: CGFloat,
        position: WorkspaceSidebarPosition
    ) -> CGFloat {
        let sanitizedTotalWidth = max(0, totalWidth.isFinite ? totalWidth : 0)
        let sanitizedSidebarWidth = min(max(0, sidebarWidth.isFinite ? sidebarWidth : 0), sanitizedTotalWidth)
        switch position {
        case .left:
            return sanitizedSidebarWidth
        case .right:
            return sanitizedTotalWidth - sanitizedSidebarWidth
        }
    }

    static func reservedTrailingWorkspaceSidebarWidth(
        workspaceSidebarWidth: CGFloat,
        workspaceSidebarVisible: Bool,
        workspaceSidebarPosition: WorkspaceSidebarPosition
    ) -> CGFloat {
        guard workspaceSidebarVisible, workspaceSidebarPosition == .right else { return 0 }
        return max(0, workspaceSidebarWidth.isFinite ? workspaceSidebarWidth : 0)
    }

    static func rightSidebarDividerX(
        totalWidth: CGFloat,
        rightSidebarWidth: CGFloat,
        workspaceSidebarWidth: CGFloat,
        workspaceSidebarVisible: Bool,
        workspaceSidebarPosition: WorkspaceSidebarPosition
    ) -> CGFloat {
        let sanitizedTotalWidth = max(0, totalWidth.isFinite ? totalWidth : 0)
        let sanitizedRightSidebarWidth = max(0, rightSidebarWidth.isFinite ? rightSidebarWidth : 0)
        let reservedWorkspaceSidebarWidth = reservedTrailingWorkspaceSidebarWidth(
            workspaceSidebarWidth: workspaceSidebarWidth,
            workspaceSidebarVisible: workspaceSidebarVisible,
            workspaceSidebarPosition: workspaceSidebarPosition
        )
        return max(0, sanitizedTotalWidth - reservedWorkspaceSidebarWidth - sanitizedRightSidebarWidth)
    }
}
