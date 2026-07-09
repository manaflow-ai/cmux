import Bonsplit
import CmuxRemoteWorkspace
import SwiftUI

/// Renders one mirrored tmux window's pane tree.
///
/// Two rendering modes, chosen by whether exact frames are available:
///
/// - **Imposed** (steady state): every pane gets EXACTLY the pixel frame its
///   the pane sizes tmux assigned occupy (``RemoteTmuxMirrorFrames``, edge-rail math in
///   device pixels), so each surface renders precisely the grid tmux thinks
///   it has and live `%output` paints faithfully — the render follows tmux's
///   layout. Placement is absolute in a fixed `topLeading` left-to-right space:
///   tmux coordinates are absolute, so sibling order must not flip under RTL
///   locales, and when a tmux layout briefly exceeds the container (a co-attached
///   client constraining the size) the overflow clips at the trailing edge.
///
/// - **Proportional** (transient): while the render constants are unknown or
///   tmux's layout doesn't yet match the pushed size (drag mid-flight, attach
///   settling), children divide the live pixels in proportion to their assigned
///   cells — always fits, tracks the window edge at frame rate, and snaps to
///   imposed frames when the matching tmux layout lands.
@MainActor
struct RemoteTmuxLayoutContainer: View {
    let node: RemoteTmuxLayoutNode
    let frames: RemoteTmuxMirrorFrames?
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

    var body: some View {
        Group {
            if let frames {
                imposed(frames)
            } else {
                // Transient mode reserves the SAME chrome rows as imposed
                // mode — the top strip here, cell-high divider strips inside
                // the split — with the last-known labels, so a drag only
                // interpolates pane sizes and the title rows never blink.
                VStack(spacing: 0) {
                    RemoteTmuxTransientStrip(
                        axis: .horizontal,
                        segments: RemoteTmuxTransientStrip.topEdgeSegments(
                            of: node, within: node, mirror: mirror
                        ),
                        appearance: appearance
                    )
                    .frame(height: mirror.stripRowHeightPt)
                    RemoteTmuxProportionalSplit(
                        node: node,
                        mirror: mirror,
                        appearance: appearance,
                        isVisibleInUI: isVisibleInUI,
                        portalPriority: portalPriority,
                        onClosePane: onClosePane
                    )
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .clipped()
    }

    private func imposed(_ frames: RemoteTmuxMirrorFrames) -> some View {
        // Panes without a computed frame (mid-teardown) are omitted from both
        // lists, keeping subview order aligned with the frame list the layout
        // places: dividers first (below the panes), then panes in tree order.
        let paneIds = node.paneIDsInOrder.filter { frames.paneFramesPt[$0] != nil }
        let orderedFrames = frames.dividersPt + paneIds.compactMap { frames.paneFramesPt[$0] }
        // The active pane is marked by a dot in the strip ABOVE it (its
        // title row — the top band for window-top panes, the separator strip
        // for stacked ones). Strips are rows/columns tmux allocated, so the
        // indicator can never sit over pane content — the constraint that
        // killed the over-content corner-dot and edge-stroke designs.
        // Each pane's header segment: the sub-range of the strip directly
        // above it, carrying its tmux-style label (`index "title"`) and,
        // when active, the dot — so no strip is ever a blank dead band.
        let headerSegments: [RemoteTmuxDividerStrip.Segment] = paneIds.compactMap { paneId in
            guard let frame = frames.paneFramesPt[paneId] else { return nil }
            // Label text renders ONLY while tmux itself draws header rows —
            // a stock tmux shows no titles anywhere, and faithful means
            // matching that. The dot (cmux's one addition) shows regardless.
            return RemoteTmuxDividerStrip.Segment(
                paneId: paneId,
                xRange: frame.minX...frame.maxX,
                top: frame.minY,
                label: mirror.tmuxTitleRowsVisible ? (mirror.paneHeaderLabels[paneId] ?? "") : "",
                isActive: mirror.activePaneId == paneId
            )
        }
        return RemoteTmuxImposedFrameLayout(frames: orderedFrames) {
            ForEach(Array(frames.dividersPt.enumerated()), id: \.offset) { _, rect in
                RemoteTmuxDividerStrip(
                    rect: rect, appearance: appearance, segments: headerSegments
                )
            }
            ForEach(paneIds, id: \.self) { paneId in
                RemoteTmuxPaneLeaf(
                    paneId: paneId,
                    mirror: mirror,
                    appearance: appearance,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onClosePane: onClosePane
                )
            }
        }
        .background(Color(nsColor: appearance.backgroundColor))
    }
}
