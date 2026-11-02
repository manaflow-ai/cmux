import AppKit
import Foundation
import SwiftUI

/// Mounts one immutable workspace-row projection below the lazy-list boundary.
struct SidebarWorkspaceRowView: View {
    let snapshot: SidebarWorkspaceRowSnapshot
    let actions: SidebarWorkspaceRowActions
    let shouldCollectWorkspaceDropTargets: Bool

    var body: some View {
        TabItemView(snapshot: snapshot, actions: actions)
            .equatable()
            .id(snapshot.workspaceId)
            .accessibilityIdentifier("sidebarWorkspace.\(snapshot.workspaceId.uuidString)")
            .sidebarWorkspaceFrameAnchor(
                id: snapshot.workspaceId,
                isEnabled: shouldCollectWorkspaceDropTargets
            )
            .sidebarPointerFrameReporting(
                onFrameChange: actions.onPointerFrameChange,
                onDisappear: actions.onPointerFrameDisappear
            )
            .padding(
                .leading,
                snapshot.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            // Drawn outside TabItemView so TabItemView and its Equatable
            // contract stay untouched. The overlay carries its own
            // `isBeingDragged` dim because TabItemView's drag opacity sits
            // inside TabItemView, below this overlay.
            .overlay(alignment: .topLeading) {
                if let guide = snapshot.groupGuide {
                    SidebarWorkspaceMemberGuideOverlay(
                        guide: guide,
                        rowSpacing: snapshot.rowSpacing,
                        fontScale: snapshot.settings.sidebarFontScale,
                        isBeingDragged: snapshot.isBeingDragged
                    )
                }
            }
            .contentShape(Rectangle())
    }
}

/// The member indent guide beside a grouped SwiftUI row. Mirrors the AppKit
/// cell's layer-backed guide: a `guideWidth`-wide segment centered in the
/// member gutter (`guideCenterX` from the row's leading edge), extending half
/// a row spacing into the inter-row gap so adjacent segments join, stopping
/// `guideEndRunBottomInset` short of the bottom when this row ends its run.
struct SidebarWorkspaceMemberGuideOverlay: View {
    let guide: SidebarGroupGuide
    let rowSpacing: CGFloat
    let fontScale: CGFloat
    let isBeingDragged: Bool

    /// Dim applied to the guide for the dragged row, matching the AppKit
    /// cell-wide `alphaValue` dim so both renderers fade the guide together.
    static let draggedOpacity: Double = 0.6

    var resolvedOpacity: Double { isBeingDragged ? Self.draggedOpacity : 1 }

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: guide.color))
            .frame(width: SidebarWorkspaceGroupingMetrics.guideWidth)
            .padding(.top, -rowSpacing / 2)
            .padding(
                .bottom,
                guide.endsRun
                    ? SidebarWorkspaceGroupingMetrics.guideEndRunBottomInset(fontScale: fontScale)
                    : -rowSpacing / 2
            )
            .padding(
                .leading,
                SidebarWorkspaceGroupingMetrics.guideCenterX
                    - SidebarWorkspaceGroupingMetrics.guideWidth / 2
            )
            .opacity(resolvedOpacity)
    }
}
