import Bonsplit
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

/// Places every subview at a precomputed absolute frame (tmux's pane sizes in
/// points).
///
/// The layout's own size is always exactly the size its parent gives it —
/// never a size computed from the pane frames. That rule is load-bearing:
/// pane frames grow with the container, so if this view told its parent "I
/// am as big as my panes", any parent that listens (the workspace layout,
/// the window) would resize to fit the panes, the panes would grow to fit
/// the new size, and so on forever. It also has to stay shrinkable for the
/// same reason: a view that refuses to go below its pane widths stops
/// receiving size changes at all once the window gets narrow. When the panes
/// are momentarily bigger than the space (tmux hasn't applied our latest
/// size yet), the extra clips at the right/bottom edge, matching tmux's
/// top-left coordinate system.
private struct RemoteTmuxImposedFrameLayout: Layout {
    let frames: [CGRect]

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (index, subview) in subviews.enumerated() {
            // Count mismatch would mean the body's subview list drifted from
            // `frames`; hide the orphan rather than guessing a position.
            guard index < frames.count else {
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
                continue
            }
            let frame = frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}

/// One divider strip: a tmux border row/column, drawn the way tmux draws it —
/// a full separator cell of pane background with a thin line through the
/// middle, so the gap reads as a hairline rather than a solid slab.
/// Horizontal strips double as the header row of the panes below them,
/// carrying each pane's tmux-style title and the active-pane dot.
private struct RemoteTmuxDividerStrip: View {
    /// One pane's header info: the x-span it occupies, the y its top edge
    /// sits at (to find the strip directly above it), its tmux-style label
    /// (`index "title"`), and whether it is tmux's active pane.
    struct Segment {
        let paneId: Int
        let xRange: ClosedRange<CGFloat>
        let top: CGFloat
        let label: String
        let isActive: Bool
    }

    let rect: CGRect
    let appearance: PanelAppearance
    let segments: [Segment]
    @Environment(\.displayScale) private var displayScale

    /// Minimum room for the label itself; with the 12pt of margins
    /// subtracted first, labels hide once the pane's visible span drops
    /// below ~52pt — narrower than that they'd collide with a neighbor's.
    private static let minimumLabelWidth: CGFloat = 40

    var body: some View {
        // True hairline, like tmux's box-drawing border glyphs: one DEVICE
        // pixel, not one point (a 2pt bar reads as a slab next to a real
        // tmux client).
        let line = 1 / max(1, displayScale)
        let horizontal = rect.width >= rect.height
        ZStack(alignment: .topLeading) {
            Color(nsColor: appearance.backgroundColor)
            if horizontal {
                appearance.dividerColor
                    .frame(width: rect.width, height: line)
                    .offset(y: (rect.height - line) / 2)
                // This strip is the header row of every pane whose top edge
                // rests on it: render each such pane's title inset on the
                // line, tmux-style (`─ 0 "title" ─`), dot for the active
                // pane. Colors derive from the terminal's own foreground —
                // Color.secondary on a dark terminal is how the old header
                // buttons became invisible.
                ForEach(headerSegmentsOnThisStrip, id: \.paneId) { segment in
                    let visibleStart = max(segment.xRange.lowerBound, rect.minX)
                    let visibleWidth = min(segment.xRange.upperBound, rect.maxX) - visibleStart - 12
                    if segment.isActive || !segment.label.isEmpty,
                       visibleWidth >= Self.minimumLabelWidth {
                        RemoteTmuxStripLabel(
                            label: segment.label, isActive: segment.isActive,
                            appearance: appearance
                        )
                        .frame(maxWidth: visibleWidth, alignment: .leading)
                        .frame(height: rect.height)
                        .offset(x: visibleStart - rect.minX + 6)
                    }
                }
            } else {
                appearance.dividerColor
                    .frame(width: line, height: rect.height)
                    .offset(x: (rect.width - line) / 2)
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }

    /// The panes whose header row this strip is: their top edge rests on the
    /// strip's bottom edge (within a rail-bias tolerance, in points) and
    /// their x-span overlaps it.
    private var headerSegmentsOnThisStrip: [Segment] {
        segments.filter { segment in
            abs(rect.maxY - segment.top) < 2 &&
                segment.xRange.upperBound > rect.minX &&
                segment.xRange.lowerBound < rect.maxX
        }
    }
}

/// One pane leaf: the terminal panel, chrome-free — pane actions live in its
/// context menu and the active-pane signal on the adjacent divider strips.
/// Shared by both rendering modes.
@MainActor
struct RemoteTmuxPaneLeaf: View {
    let paneId: Int
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

    var body: some View {
        if let panel = mirror.panel(forPane: paneId),
           let syntheticPaneId = mirror.syntheticPaneID(forPane: paneId) {
            TerminalPanelView(
                panel: panel,
                paneId: syntheticPaneId,
                isFocused: mirror.activePaneId == paneId,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                isSplit: true,
                appearance: appearance,
                hasUnreadNotification: false,
                terminalAgentContext: "",
                onFocus: { mirror.focus(pane: paneId) },
                onResumeAgentHibernation: {},
                onAutoResumeAgentHibernation: {},
                onTriggerFlash: {}
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                Button(String(localized: "remoteTmux.pane.splitRight", defaultValue: "Split Right")) {
                    mirror.requestSplit(fromPane: paneId, vertical: false)
                }
                Button(String(localized: "remoteTmux.pane.splitDown", defaultValue: "Split Down")) {
                    mirror.requestSplit(fromPane: paneId, vertical: true)
                }
                Divider()
                Button(String(localized: "remoteTmux.pane.close", defaultValue: "Close Pane"), role: .destructive) {
                    onClosePane(paneId)
                }
            }
            .id(paneId)
            .background(Color(nsColor: appearance.backgroundColor))
        } else {
            Color(nsColor: appearance.backgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The transient proportional renderer: recursive stacks dividing live pixels
/// by assigned cell weights. Never used at steady state — see
/// ``RemoteTmuxLayoutContainer`` for when each mode applies.
@MainActor
struct RemoteTmuxProportionalSplit: View {
    let node: RemoteTmuxLayoutNode
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

    var body: some View {
        switch node.content {
        case let .pane(paneId):
            RemoteTmuxPaneLeaf(
                paneId: paneId,
                mirror: mirror,
                appearance: appearance,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                onClosePane: onClosePane
            )
        case let .horizontal(children):
            splitStack(children: children, axis: .horizontal)
        case let .vertical(children):
            splitStack(children: children, axis: .vertical)
        }
    }

    /// Children interleaved with cell-sized divider strips (the same chrome
    /// imposed mode draws), so the transient render is visually continuous
    /// with the imposed one: a vertical gap is the title strip of the panes
    /// below it (last-known labels pinned through the drag), a horizontal
    /// gap is a hairline separator column.
    @ViewBuilder
    private func splitStack(children: [RemoteTmuxLayoutNode], axis: Axis) -> some View {
        let weights = children.map { CGFloat(axis == .horizontal ? $0.width : $0.height) }
        let thickness = axis == .horizontal ? mirror.stripColumnWidthPt : mirror.stripRowHeightPt
        RemoteTmuxWeightedSplitLayout(axis: axis, weights: weights, spacing: thickness) {
            ForEach(children.indices, id: \.self) { index in
                if index > 0 {
                    RemoteTmuxTransientStrip(
                        axis: axis == .horizontal ? .vertical : .horizontal,
                        segments: axis == .vertical
                            ? RemoteTmuxTransientStrip.topEdgeSegments(
                                of: children[index], within: node, mirror: mirror
                            )
                            : [],
                        appearance: appearance
                    )
                }
                RemoteTmuxProportionalSplit(
                    node: children[index],
                    mirror: mirror,
                    appearance: appearance,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onClosePane: onClosePane
                )
            }
        }
    }
}

/// A divider strip for the TRANSIENT render: same hairline + labels + dot as
/// ``RemoteTmuxDividerStrip``, but segments are positioned by fractions of
/// the strip's own width (the transient layout has no precomputed absolute
/// frames — panes are re-divided proportionally every frame of a drag).
private struct RemoteTmuxTransientStrip: View {
    struct Segment {
        let paneId: Int
        let startFraction: CGFloat
        let endFraction: CGFloat
        let label: String
        let isActive: Bool
    }

    let axis: Axis // of the strip itself: horizontal = a row strip
    let segments: [Segment]
    let appearance: PanelAppearance
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let line = 1 / max(1, displayScale)
            ZStack(alignment: .topLeading) {
                Color(nsColor: appearance.backgroundColor)
                if axis == .horizontal {
                    appearance.dividerColor
                        .frame(width: proxy.size.width, height: line)
                        .offset(y: (proxy.size.height - line) / 2)
                    ForEach(segments, id: \.paneId) { segment in
                        let start = segment.startFraction * proxy.size.width
                        let width = (segment.endFraction - segment.startFraction) * proxy.size.width - 12
                        if segment.isActive || !segment.label.isEmpty, width >= 40 {
                            RemoteTmuxStripLabel(
                                label: segment.label, isActive: segment.isActive,
                                appearance: appearance
                            )
                            .frame(maxWidth: width, alignment: .leading)
                            .frame(height: proxy.size.height)
                            .offset(x: start + 6)
                        }
                    }
                } else {
                    appearance.dividerColor
                        .frame(width: line, height: proxy.size.height)
                        .offset(x: (proxy.size.width - line) / 2)
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }

    /// The header segments for the strip ABOVE `subtree`: its top-edge panes
    /// (the ones whose tmux title row that strip is), x-spans as fractions of
    /// `root`'s width. Uses the leaves' REAL tmux columns, so segment spans
    /// track the same proportions the split layout divides by.
    @MainActor
    static func topEdgeSegments(
        of subtree: RemoteTmuxLayoutNode,
        within root: RemoteTmuxLayoutNode,
        mirror: RemoteTmuxWindowMirror
    ) -> [Segment] {
        let rootWidth = CGFloat(max(1, root.width))
        var minY = Int.max
        var leaves: [(id: Int, x: Int, width: Int, y: Int)] = []
        func walk(_ n: RemoteTmuxLayoutNode) {
            switch n.content {
            case let .pane(id):
                leaves.append((id, n.x, n.width, n.y))
                minY = min(minY, n.y)
            case let .horizontal(children), let .vertical(children):
                children.forEach(walk)
            }
        }
        walk(subtree)
        return leaves.filter { $0.y == minY }.map { leaf in
            Segment(
                paneId: leaf.id,
                startFraction: CGFloat(max(0, leaf.x)) / rootWidth,
                endFraction: CGFloat(max(0, leaf.x) + leaf.width) / rootWidth,
                label: mirror.tmuxTitleRowsVisible ? (mirror.paneHeaderLabels[leaf.id] ?? "") : "",
                isActive: mirror.activePaneId == leaf.id
            )
        }
    }
}

/// Divides the container along one axis proportionally to tmux's assigned
/// cells, with a fixed-thickness divider strip between children — the
/// transient fallback's split arithmetic as a proper `Layout` (single pass,
/// no geometry read-back into view state). Subviews alternate
/// [strip?, child, strip, child, …]: children (even positions in each
/// child/strip pair) share the weighted remainder; each strip fills the
/// `spacing`-thick gap after the previous child.
struct RemoteTmuxWeightedSplitLayout: Layout {
    let axis: Axis
    let weights: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let childCount = (subviews.count + 1) / 2
        let total = max(1, weights.reduce(0, +))
        let span = axis == .horizontal ? bounds.width : bounds.height
        let usable = max(1, span - spacing * CGFloat(max(0, childCount - 1)))
        var cursor = axis == .horizontal ? bounds.minX : bounds.minY
        var childIndex = 0
        for (index, subview) in subviews.enumerated() {
            let isStrip = index.isMultiple(of: 2) == false
            let dimension: CGFloat
            if isStrip {
                dimension = spacing
            } else {
                let weight = childIndex < weights.count ? weights[childIndex] : 1
                dimension = usable * weight / total
                childIndex += 1
            }
            let frame: CGRect = axis == .horizontal
                ? CGRect(x: cursor, y: bounds.minY, width: dimension, height: bounds.height)
                : CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: dimension)
            subview.place(
                at: frame.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
            cursor += dimension
        }
    }
}


/// One strip label: the active-pane dot plus the pane's header text, styled
/// identically in the imposed and transient renders (the drag-time strip must
/// be indistinguishable from the settled one). Colors derive from the
/// terminal's own foreground — fixed grays go invisible on themed backgrounds.
struct RemoteTmuxStripLabel: View {
    let label: String
    let isActive: Bool
    let appearance: PanelAppearance

    var body: some View {
        HStack(spacing: 5) {
            if isActive {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        Color(nsColor: appearance.foregroundColor)
                            .opacity(isActive ? 0.95 : 0.65)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 5)
        .background(Color(nsColor: appearance.backgroundColor))
    }
}
