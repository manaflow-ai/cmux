import AppKit
@testable import CmuxNextLayout
import Testing

/// Backing scales the handles are checked at.
nonisolated private let dividerScales: [CGFloat] = [1, 2]

/// Every resize handle draws its line in the exact middle of the gap it
/// resizes (u2345, dogfood 2026-10-19): split dividers, column edges, dock
/// edges and row edges, on both axes, nested, at 1x and 2x, and for any
/// split ratio a drag sets. The line is checked where the screen draws it: a
/// `DividerHandleView` placed at the handle's hit frame snapped to device
/// pixels, as `ScreenContentView.applyPresentation` places it.
@MainActor
struct DividerHandleCenteringTests {
    // MARK: Styles

    /// The density defaults (`Metrics`): compact pads 2 pt with a 6 pt column gap,
    /// comfortable 4 pt with 8 pt; edge to edge and a fractional padding too.
    private static let styles: [LayoutStyle] = {
        func style(padding: CGFloat, columnGap: CGFloat, divider: CGFloat = 1, hit: CGFloat = 7) -> LayoutStyle {
            var style = LayoutStyle()
            style.panePadding = padding
            style.columnGap = columnGap
            style.dividerThickness = divider
            style.dividerHitThickness = hit
            return style
        }
        return [
            style(padding: 2, columnGap: 6),
            style(padding: 4, columnGap: 8),
            style(padding: 0, columnGap: 0),
            style(padding: 2.5, columnGap: 7),
            style(padding: 3, columnGap: 6, divider: 2, hit: 8),
        ]
    }()

    // MARK: Split dividers

    private static let trees: [SplitNode] = [
        .split("h", axis: .horizontal, ratio: 0.37, a: .leaf("a"), b: .leaf("b")),
        .split("v", axis: .vertical, ratio: 0.61, a: .leaf("a"), b: .leaf("b")),
        .split("outer", axis: .horizontal, ratio: 0.43,
               a: .split("left", axis: .vertical, ratio: 0.29, a: .leaf("a"), b: .leaf("b")),
               b: .split("right", axis: .vertical, ratio: 0.55, a: .leaf("c"),
                         b: .split("inner", axis: .horizontal, ratio: 0.5, a: .leaf("d"), b: .leaf("e")))),
    ]

    @Test(arguments: dividerScales, [0.2, 0.333, 0.5, 0.517, 0.8])
    func splitDividerLinesSitInTheMiddleOfTheirGap(scale: CGFloat, dragRatio: Double) {
        for style in Self.styles {
            for tree in Self.trees + [Self.retargeted(Self.trees[2], ratio: dragRatio)] {
                let result = SplitGeometry.layout(tree, in: CGRect(x: 0, y: 0, width: 1201, height: 803), style: style, scale: scale)
                #expect(!result.dividers.isEmpty)
                for divider in result.dividers {
                    // The two sides are padded alike, so the gap between their content is centered on the divider.
                    let gap = Self.span(divider.frame, axis: divider.axis, grownBy: style.panePadding)
                    expectCentered(kind: .split(divider.id), axis: divider.axis, hit: divider.hitFrame, gap: gap,
                                   style: style, scale: scale, label: "split \(divider.id.rawValue) \(Self.describe(style)) @\(scale)x")
                }
            }
        }
    }

    // MARK: Column edges

    @Test(arguments: dividerScales)
    func columnEdgeLinesSitInTheMiddleOfTheColumnGap(scale: CGFloat) throws {
        let columns = [
            LayoutColumn(id: "c1", width: 0.41, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.337, root: .leaf("p2")),
            LayoutColumn(id: "c3", width: 0.5, root: .leaf("p3")),
        ]
        for style in Self.styles {
            let geometry = ScreenGeometry.compute(.columns(columns), viewport: CGSize(width: 1601, height: 901), style: style, scale: scale)
            let shift = geometry.viewShift(offset: 0)
            let frames = try columns.map { try #require(geometry.columns[$0.id]).offsetBy(dx: shift, dy: 0) }
            for (index, column) in columns.enumerated() {
                let edge = try #require(geometry.columnEdges.first { $0.column == column.id })
                // The gap to the next column, or the strip's trailing gap after the last one.
                let nextMinX = index + 1 < frames.count ? frames[index + 1].minX : frames[index].maxX + style.stripGap
                let gap = (frames[index].maxX - style.panePadding)...(nextMinX + style.panePadding)
                expectCentered(kind: .columnEdge(column.id), axis: .horizontal, hit: edge.hitFrame.offsetBy(dx: shift, dy: 0),
                               gap: gap, style: style, scale: scale, label: "column \(column.id.rawValue) \(Self.describe(style)) @\(scale)x")
            }
        }
    }

    // MARK: Dock edges

    @Test(arguments: dividerScales, [DockEdge.left, .right, .top, .bottom])
    func dockEdgeLinesSitInTheMiddleOfTheGapBesideTheDock(scale: CGFloat, edge: DockEdge) throws {
        for mode in DockMode.allCases {
            let columns = [
                LayoutColumn(id: "dock", width: 0.3, root: .leaf("docked"), dock: DockColumn(edge: edge, mode: mode)),
                LayoutColumn(id: "strip", width: 0.5, root: .leaf("p1")),
            ]
            for style in Self.styles {
                let geometry = ScreenGeometry.compute(.columns(columns), viewport: CGSize(width: 1601, height: 1001), style: style, scale: scale)
                let dock = try #require(geometry.dock.first { $0.column == "dock" }).frame
                let handle = try #require(geometry.columnEdges.first { $0.column == "dock" })
                // `DockStripGeometry.place` keeps one `stripGap` between the dock and the strip's
                // panes (docked or overlay); the handle resizes across that gap.
                let p = style.panePadding, g = style.stripGap
                let gap: ClosedRange<CGFloat> = switch edge {
                case .left: (dock.maxX - p)...(dock.maxX + g + p)
                case .right: (dock.minX - g - p)...(dock.minX + p)
                case .top: (dock.maxY - p)...(dock.maxY + g + p)
                case .bottom: (dock.minY - g - p)...(dock.minY + p)
                }
                if edge == .left, mode == .docked {
                    let strip = try #require(geometry.columns["strip"]).offsetBy(dx: geometry.viewShift(offset: 0), dy: 0)
                    #expect(abs(strip.minX - (dock.maxX + g)) < 0.001, "the strip starts one gap right of a left dock")
                }
                #expect(handle.axis == (edge.isBand ? .vertical : .horizontal))
                expectCentered(kind: .columnEdge("dock"), axis: handle.axis, hit: handle.hitFrame, gap: gap, style: style, scale: scale,
                               label: "\(edge) \(mode) dock \(Self.describe(style)) @\(scale)x")
            }
        }
    }

    // MARK: Row edges

    @Test(arguments: dividerScales)
    func rowEdgeLinesSitInTheMiddleOfTheRowGap(scale: CGFloat) throws {
        let column = LayoutColumn(id: "rows", width: 0.6, root: .leaf("r1p"), rows: [
            LayoutRow(id: "r1", height: 337, root: .leaf("r1p")),
            LayoutRow(id: "r2", height: 251, root: .leaf("r2p")),
            LayoutRow(id: "r3", height: 412, root: .leaf("r3p")),
        ])
        for style in Self.styles {
            let geometry = ScreenGeometry.compute(.columns([column]), viewport: CGSize(width: 1401, height: 1003), style: style, scale: scale)
            let stack = try #require(geometry.rowStacks["rows"])
            let shift = geometry.viewShift(offset: 0)
            #expect(geometry.rowEdges.count == 2)
            for edge in geometry.rowEdges {
                let upper = try #require(stack.frame(of: edge.upper)), lower = try #require(stack.frame(of: edge.lower))
                let gap = (upper.maxY - style.panePadding)...(lower.minY + style.panePadding)
                expectCentered(kind: .rowEdge("rows", edge.upper), axis: .vertical, hit: edge.hitFrame.offsetBy(dx: shift, dy: 0),
                               gap: gap, style: style, scale: scale, label: "row \(edge.upper.rawValue) \(Self.describe(style)) @\(scale)x")
            }
        }
    }

    // MARK: Mid-spring

    /// A divider springing between two ratios (a drag release, a Cmd-D chain
    /// resize) draws its line centered and crisp in every frame between them:
    /// both ends have the same hit width, so snapping the moving frame to
    /// pixels never changes its width.
    @Test(arguments: dividerScales)
    func aSpringingDividerStaysCenteredBetweenItsEnds(scale: CGFloat) throws {
        let rect = CGRect(x: 0, y: 0, width: 1201, height: 803)
        for style in Self.styles {
            func divider(_ ratio: Double) throws -> DividerGeometry {
                let tree = SplitNode.split("h", axis: .horizontal, ratio: ratio, a: .leaf("a"), b: .leaf("b"))
                return try #require(SplitGeometry.layout(tree, in: rect, style: style, scale: scale).dividers.first)
            }
            let from = try divider(0.3), to = try divider(0.62)
            #expect(from.hitFrame.width == to.hitFrame.width)
            for progress in [0.13, 0.5, 0.87] as [CGFloat] {
                let shift = (to.frame.minX - from.frame.minX) * progress
                let gap = Self.span(from.frame.offsetBy(dx: shift, dy: 0), axis: .horizontal, grownBy: style.panePadding)
                expectCentered(kind: .split("h"), axis: .horizontal, hit: from.hitFrame.offsetBy(dx: shift, dy: 0), gap: gap,
                               style: style, scale: scale, label: "spring \(progress) \(Self.describe(style)) @\(scale)x")
            }
        }
    }

    // MARK: Helpers

    /// Places a handle at `hit` the way the screen does (`applyPresentation`
    /// snaps the frame to device pixels; the view draws its line in the
    /// middle of its bounds, `DividerHandleViewDrawsItsLineCentered`), then
    /// checks the line: centered on `gap` along `axis` (within the half device
    /// pixel an odd/even mismatch leaves), on device pixels, and the hit area
    /// covers the gap. No AppKit view here: hundreds of cases stay pure.
    private func expectCentered(kind: DividerHandleView.Kind, axis: SplitAxis, hit: CGRect, gap: ClosedRange<CGFloat>,
                                style: LayoutStyle, scale: CGFloat, label: String,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let frame = hit.pixelEdges(scale)
        let edge: Bool = if case .columnEdge = kind { true } else { false }
        let t = edge ? max(style.dividerThickness, 2) : style.dividerThickness
        let (hitMin, hitMax) = axis == .horizontal ? (frame.minX, frame.maxX) : (frame.minY, frame.maxY)
        let lineMin = hitMin + ((hitMax - hitMin) - t) / 2, lineMax = lineMin + t
        let gapCenter = (gap.lowerBound + gap.upperBound) / 2
        let lineCenter = (lineMin + lineMax) / 2
        let epsilon: CGFloat = 0.001
        #expect(abs(lineCenter - gapCenter) <= 0.5 / scale + epsilon,
                "\(label): line center \(lineCenter) but gap \(gap.lowerBound)...\(gap.upperBound) centers at \(gapCenter)",
                sourceLocation: sourceLocation)
        #expect(Self.onPixel(lineMin, scale) && Self.onPixel(lineMax, scale),
                "\(label): line \(lineMin)...\(lineMax) straddles a device pixel at \(scale)x", sourceLocation: sourceLocation)
        #expect(hitMin <= gap.lowerBound + 0.5 / scale + epsilon && hitMax >= gap.upperBound - 0.5 / scale - epsilon,
                "\(label): hit area \(hitMin)...\(hitMax) does not cover the gap \(gap)", sourceLocation: sourceLocation)
    }

    private static func onPixel(_ value: CGFloat, _ scale: CGFloat) -> Bool {
        abs((value * scale).rounded() - value * scale) < 0.001
    }

    private static func span(_ rect: CGRect, axis: SplitAxis, grownBy padding: CGFloat) -> ClosedRange<CGFloat> {
        axis == .horizontal ? (rect.minX - padding)...(rect.maxX + padding) : (rect.minY - padding)...(rect.maxY + padding)
    }

    /// `node` with its outermost ratio set to `ratio`: a divider mid-drag.
    private static func retargeted(_ node: SplitNode, ratio: Double) -> SplitNode {
        guard case let .split(id, axis, _, a, b) = node else { return node }
        return .split(id, axis: axis, ratio: ratio, a: a, b: b)
    }

    private static func describe(_ style: LayoutStyle) -> String {
        "pad \(style.panePadding) gap \(style.columnGap) line \(style.dividerThickness) hit \(style.dividerHitThickness)"
    }
}

/// The handle view draws its line in the middle of its bounds, the contract
/// the geometry checks above rely on (one handle per kind, no layout pass).
@MainActor
struct DividerHandleViewDrawsItsLineCentered {
    @Test func everyKindDrawsItsLineInTheMiddleOfItsFrame() {
        let cases: [(DividerHandleView.Kind, SplitAxis, CGRect, CGFloat)] = [
            (.split("s"), .horizontal, CGRect(x: 100, y: 0, width: 7, height: 300), 1),
            (.split("s"), .vertical, CGRect(x: 0, y: 200, width: 300, height: 9), 1),
            (.columnEdge("c"), .horizontal, CGRect(x: 40, y: 0, width: 8, height: 300), 2),
            (.rowEdge("c", "r"), .vertical, CGRect(x: 0, y: 60, width: 300, height: 7), 1),
        ]
        for (kind, axis, frame, drawn) in cases {
            let view = DividerHandleView(kind: kind, axis: axis)
            view.lineThickness = 1
            view.frame = frame
            view.layout()
            // The line layer, in the view's own coordinates.
            guard let line = view.layer?.sublayers?.first?.frame else {
                Issue.record("\(kind): no line layer")
                continue
            }
            let bounds = CGRect(origin: .zero, size: frame.size)
            if axis == .horizontal {
                #expect(abs(line.midX - bounds.midX) < 0.001 && abs(line.width - drawn) < 0.001, "\(kind): line \(line) in \(bounds)")
            } else {
                #expect(abs(line.midY - bounds.midY) < 0.001 && abs(line.height - drawn) < 0.001, "\(kind): line \(line) in \(bounds)")
            }
        }
    }
}
