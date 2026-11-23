public import CoreGraphics

/// A rounded container that holds controls (a dialog, a toast, a hint, a card), drawn concentric with them
/// (Lawrence 2026-11-15: "all dialogs needs concentric padding with buttons inside").
///
/// One rule ties three numbers: the container's corner is the control's corner plus the padding between the
/// container's edge and the control (`outer = child + padding`, the ``ConcentricCorners`` rule read outward),
/// and that padding is the same on the top, the bottom and the near side. The control's corner is the one
/// button corner (`Metrics.buttonCornerRadius`), so the container rounds from it; a capsule container
/// (``capsule(controlHeight:padding:)``) has capsule controls instead. Text that leads the container (not a
/// shape of its own) starts ``textInset`` in, clear of the corner's curve.
///
/// ```swift
/// let toast = ConcentricContainer(childRadius: 8, padding: 8)
/// toast.outerRadius            // 16: the toast's corner
/// toast.childRadius            // 8: Don't Show Again's and close's hover shape
/// toast.textInset              // 16: where the message starts
/// ConcentricContainer.capsule(controlHeight: 22, padding: 8).outerRadius  // 19: half of 38
/// ```
public nonisolated struct ConcentricContainer: Hashable, Sendable {
    /// Points from the container's edge to a control near it, the same on the top, the bottom and the near side;
    /// never negative.
    public var padding: CGFloat
    /// The corner of a control nested in the container, never negative.
    public var childRadius: CGFloat

    /// A container around controls that round by `childRadius`, `padding` in from its edges.
    /// - Parameter childRadius: The controls' corner (a negative value is 0).
    /// - Parameter padding: The gap from the container's edge to a control (a negative value is 0).
    public init(childRadius: CGFloat, padding: CGFloat) {
        self.childRadius = max(0, childRadius)
        self.padding = max(0, padding)
    }

    /// A container whose corner is fixed by something else (a window's), with controls `padding` in: the
    /// controls round by `outerRadius - padding`, at least 0.
    /// - Parameter outerRadius: The container's corner.
    /// - Parameter padding: The gap from the container's edge to a control.
    public init(outerRadius: CGFloat, padding: CGFloat) {
        self.init(childRadius: max(0, outerRadius) - max(0, padding), padding: padding)
    }

    /// A control in a container's corner (a card's or a toast's close x; Lawrence 2026-11-15: the x must be
    /// concentric with the card's corner): the same `padding` from the top and from the side, and the control
    /// rounds by the container's corner less it. A round control `side` wide centers on the corner's center
    /// (`padding = outerRadius - side / 2`); where that is less than `minimumPadding` (a small corner), the control
    /// keeps `minimumPadding` and rounds by `outerRadius - minimumPadding`, still concentric.
    ///
    /// ```swift
    /// let x = ConcentricContainer.cornerControl(outerRadius: 14, side: 16, minimumPadding: 2)
    /// x.padding                                   // 6: the x sits 6 pt from the top and the side
    /// x.childRadius(fitting: CGSize(width: 16, height: 16)) // 8: round
    /// ```
    /// - Parameter outerRadius: The container's corner.
    /// - Parameter side: The control's side.
    /// - Parameter minimumPadding: The least gap from the container's edge.
    public static func cornerControl(outerRadius: CGFloat, side: CGFloat, minimumPadding: CGFloat) -> ConcentricContainer {
        ConcentricContainer(outerRadius: outerRadius, padding: max(minimumPadding, outerRadius - side / 2))
    }

    /// The frame of a `side`-square control in the top trailing corner of `bounds`, ``padding`` from the top and
    /// the side; `flipped` is the coordinate space's (y grows down).
    public func topTrailingFrame(side: CGFloat, in bounds: CGRect, flipped: Bool) -> CGRect {
        CGRect(x: bounds.maxX - padding - side, y: flipped ? bounds.minY + padding : bounds.maxY - padding - side,
               width: side, height: side)
    }

    /// The frame of a `side`-square control centered on the vertical middle of `bounds`, with ``padding`` from
    /// its trailing edge. This keeps the control's horizontal inset tied to the surrounding surface while its
    /// vertical placement follows the content row instead of a surface corner.
    public func centeredTrailingFrame(side: CGFloat, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - padding - side, y: bounds.midY - side / 2, width: side, height: side)
    }

    /// A capsule around capsule controls `controlHeight` tall, `padding` from each edge: the container is
    /// `controlHeight + 2 * padding` tall and rounds by half of that, the controls by half their height.
    /// - Parameter controlHeight: The controls' height.
    /// - Parameter padding: The gap from the capsule's edge to a control.
    public static func capsule(controlHeight: CGFloat, padding: CGFloat) -> ConcentricContainer {
        ConcentricContainer(childRadius: max(0, controlHeight) / 2, padding: padding)
    }

    /// The container's corner: ``childRadius`` plus ``padding``, so the two curves share a center.
    public var outerRadius: CGFloat { childRadius + padding }

    /// Where text that leads the container starts: ``outerRadius`` in, clear of the corner's curve, as a
    /// control's title sits inside its own concentric shape (at least ``padding``).
    public var textInset: CGFloat { max(padding, outerRadius) }

    /// The corner of a control `size` big: ``childRadius``, at most half its shorter side.
    public func childRadius(fitting size: CGSize) -> CGFloat {
        max(0, min(childRadius, min(size.width, size.height) / 2))
    }

    /// The container's corner on a container `size` big: ``outerRadius``, at most half its shorter side
    /// (a short container is a capsule).
    public func outerRadius(fitting size: CGSize) -> CGFloat {
        max(0, min(outerRadius, min(size.width, size.height) / 2))
    }

    /// What breaks the concentric rule for a control drawn at `child` (rounded by `childRadius`) inside a
    /// container drawn at `bounds` (rounded by `outerRadius`) that means to hold its controls `padding` in, in
    /// the container's coordinates; empty when it holds. An edge of the control is near when it is within
    /// `padding + outerRadius` of the container's edge (it reads against the corner). Every near edge must be
    /// `padding` in (so top, bottom and the near side match), and a control that sits in a corner (a near top
    /// or bottom edge and a near side) must round by `outerRadius - padding`. Tests measure laid-out surfaces
    /// with it.
    /// - Parameters:
    ///   - child: The control's frame in the container's coordinates.
    ///   - childRadius: The corner the control draws (its hover or pressed shape).
    ///   - bounds: The container's frame.
    ///   - outerRadius: The corner the container draws.
    ///   - padding: The gap the container means between its edge and a control.
    ///   - tolerance: How far a measure may be off (half a point by default, the 2x pixel).
    /// - Returns: One line for each broken rule.
    public static func violations(child: CGRect, childRadius: CGFloat, in bounds: CGRect, outerRadius: CGFloat,
                                  padding: CGFloat, tolerance: CGFloat = 0.5) -> [String] {
        let insets: [(edge: String, inset: CGFloat)] = [
            ("top", child.minY - bounds.minY), ("bottom", bounds.maxY - child.maxY),
            ("leading", child.minX - bounds.minX), ("trailing", bounds.maxX - child.maxX),
        ]
        let near = insets.filter { $0.inset <= padding + outerRadius + tolerance }
        var out: [String] = []
        for edge in near where abs(edge.inset - padding) > tolerance {
            out.append("\(edge.edge) inset \(format(edge.inset)) is not the padding \(format(padding))")
        }
        let names = Set(near.map(\.edge))
        let inCorner = (names.contains("top") || names.contains("bottom")) && (names.contains("leading") || names.contains("trailing"))
        if inCorner {
            let expected = max(0, min(outerRadius - padding, min(child.width, child.height) / 2))
            if abs(childRadius - expected) > tolerance {
                out.append("child radius \(format(childRadius)) is not \(format(outerRadius)) - \(format(padding)) = \(format(expected))")
            }
        }
        return out
    }
}

/// `value` with at most two decimals, for a violation's line.
nonisolated private func format(_ value: CGFloat) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(Double(rounded))
}
