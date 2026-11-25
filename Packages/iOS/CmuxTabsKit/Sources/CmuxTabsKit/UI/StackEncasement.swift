#if os(iOS)
import SwiftUI
import UIKit

/// The outline of a stack's encasement: its rows (`StackOutlineRects`) as
/// rounded rects joined by bridges across the row gap, with the inner
/// corners where rows meet rounded too, so a stack spanning rows reads as
/// one liquid shape (the drawing's L around the first three cards).
/// Animatable: while a stack opens or folds, the rows are interpolated and
/// the outline is rebuilt every frame from them.
struct StackOutlineShape: Shape {
    var rects: StackOutlineRects
    /// Convex corner radius.
    var radius: CGFloat
    /// Concave (inner) corner radius.
    var innerRadius: CGFloat
    /// Widest gap between rows that is bridged.
    var maxGap: CGFloat

    var animatableData: AnimatablePair<CGRect.AnimatableData, AnimatablePair<CGRect.AnimatableData, CGRect.AnimatableData>> {
        get { AnimatablePair(rects.a.animatableData, AnimatablePair(rects.b.animatableData, rects.c.animatableData)) }
        set {
            rects.a.animatableData = newValue.first
            rects.b.animatableData = newValue.second.first
            rects.c.animatableData = newValue.second.second
        }
    }

    func path(in _: CGRect) -> Path {
        Path(Self.outline(rects, radius: radius, innerRadius: innerRadius, maxGap: maxGap))
    }

    // perf-hot: three rounded rects and at most three bridges, a few CGPath boolean ops per stack per frame while it morphs
    static func outline(_ rects: StackOutlineRects, radius: CGFloat, innerRadius: CGFloat, maxGap: CGFloat) -> CGPath {
        let (rows, bridges) = rects.pieces(maxGap: maxGap, overlap: radius)
        var shape: CGPath?
        for r in rows where r.width > 0.5 && r.height > 0.5 {
            let rr = min(radius, r.width / 2, r.height / 2)
            let piece = CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
            shape = shape.map { $0.union(piece) } ?? piece
        }
        for r in bridges {
            let piece = CGPath(rect: r, transform: nil)
            shape = shape.map { $0.union(piece) } ?? piece
        }
        guard let shape else { return CGMutablePath() }
        // One piece: nothing to smooth.
        guard rows.count > 1, innerRadius > 0 else { return shape }
        // Closing (grow, then shrink by the same amount) rounds the inner
        // corners where a row meets a bridge, and leaves the outer ones.
        let band = { (p: CGPath) in p.copy(strokingWithWidth: innerRadius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1) }
        let grown = shape.union(band(shape))
        return grown.subtracting(band(grown))
    }
}

/// A stack's liquid glass encasement, behind its cards in the grid's content.
/// It is drawn from the outline's bounds so the glass covers only the
/// shape; a hairline rim catches the light as glass edges do.
struct StackEncasement: View {
    var rects: StackOutlineRects
    var radius: CGFloat
    var maxGap: CGFloat
    var onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The encasement's own coordinates: the rows' union, so the frame and
        // the outline move together (`EncasementFrame`).
        EncasementFrame(rects: rects) { local, bounds in
            let shape = StackOutlineShape(rects: local, radius: radius, innerRadius: 10, maxGap: maxGap)
            Color.clear
                .frame(width: bounds.width, height: bounds.height)
                .glassEffect(.regular.tint(tint), in: shape)
                .overlay {
                    shape.stroke(rim, lineWidth: 0.75)
                }
                .contentShape(shape)
                .onTapGesture(perform: onTap)
                .offset(x: bounds.minX, y: bounds.minY)
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.22)
    }

    private var rim: Color {
        colorScheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.7)
    }
}

/// Re-runs its content on every animation frame with the interpolated rows
/// (in content coordinates) and gives it the rows in its own coordinates.
private struct EncasementFrame<Content: View>: View, Animatable {
    var rects: StackOutlineRects
    @ViewBuilder var content: (StackOutlineRects, CGRect) -> Content

    // The rows are plain values: SwiftUI interpolates them off the main actor's view body.
    nonisolated var animatableData: AnimatablePair<CGRect.AnimatableData, AnimatablePair<CGRect.AnimatableData, CGRect.AnimatableData>> {
        get { AnimatablePair(rects.a.animatableData, AnimatablePair(rects.b.animatableData, rects.c.animatableData)) }
        set {
            rects.a.animatableData = newValue.first
            rects.b.animatableData = newValue.second.first
            rects.c.animatableData = newValue.second.second
        }
    }

    var body: some View {
        let bounds = rects.a.union(rects.b).union(rects.c)
        let dx = -bounds.minX, dy = -bounds.minY
        let local = StackOutlineRects(a: rects.a.offsetBy(dx: dx, dy: dy), b: rects.b.offsetBy(dx: dx, dy: dy),
                                      c: rects.c.offsetBy(dx: dx, dy: dy))
        content(local, bounds)
    }
}

/// The stack's "v": a glass circle with a chevron at its first card's top
/// trailing corner (where a card's close button is). Down while the stack is
/// folded, turning up as it opens.
struct StackChevron: View {
    var isOpen: Bool
    var count: Int
    var title: String
    var action: () -> Void

    @Environment(\.tabsKitTheme) private var theme

    static let size: CGFloat = 26

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.colors.label)
                .rotationEffect(.degrees(isOpen ? -180 : 0))
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(isOpen ? "Stack \(title)" : "Show \(count) tabs in \(title)")
        .accessibilityIdentifier("tabs.stack.chevron")
        .accessibilityValue(isOpen ? "Open" : "Folded")
    }
}
#endif

#if os(iOS)
/// Every stack's chevron on the settled grid, above the live page that draws
/// the active card (so the active card leading a stack keeps its chevron).
/// Each sits at its stack's first slot and stays there while the stack opens
/// or folds; it follows the grid's scroll by itself (only this small layer
/// reads the scroll position) and fades out under the top controls and the
/// bottom bar, as the cards pass under them.
struct StackChevronLayer: View {
    var stacks: [TabStackPlan.Stack]
    /// The grid's cards in order (a stack's first card hides its chevron while swiped).
    var cardIDs: [String]
    var layout: OverviewLayout
    var scroll: GridScrollTracker
    /// A card whose chevron another layer draws (the zooming page's).
    var excluding: String? = nil
    var swipes: CardSwipeState
    var opacity: Double
    var topLimit: CGFloat
    var interactive: Bool
    var onToggle: (String) -> Void

    /// Points over which a chevron fades at the top and bottom limits.
    static let fade: CGFloat = 18

    var body: some View {
        let origin = scroll.screenOrigin
        let bottomLimit = layout.barRect.minY - 6
        ZStack(alignment: .topLeading) {
            ForEach(stacks, id: \.id) { stack in
                let r = layout.card(stack.anchor)
                // Where a card's close button is: 30 pt square at the top trailing corner.
                let center = CGPoint(x: r.maxX - 15, y: r.minY + 15)
                let y = center.y + origin.y
                let edge = min(y - StackChevron.size / 2 - topLimit, bottomLimit - (y + StackChevron.size / 2))
                let shown = max(0, min(1, edge / Self.fade + 1))
                let card = stack.anchor < cardIDs.count ? cardIDs[stack.anchor] : nil
                let swiped = card.map { swipes.isRaised($0) || swipes.menuCard == $0 || $0 == excluding } ?? false
                StackChevron(isOpen: stack.isOpen, count: stack.members.count, title: stack.title) { onToggle(stack.id) }
                    .padding(2)
                    .position(center)
                    .opacity(swiped ? 0 : shown)
                    .allowsHitTesting(interactive && !swiped && shown > 0.5)
                    .accessibilityHidden(shown < 0.5)
            }
        }
        .frame(width: layout.size.width, height: max(layout.size.height, layout.contentHeight), alignment: .topLeading)
        .offset(x: origin.x, y: origin.y)
        .opacity(opacity)
    }
}
#endif
