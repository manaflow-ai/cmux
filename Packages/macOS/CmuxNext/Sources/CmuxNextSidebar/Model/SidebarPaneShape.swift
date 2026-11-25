public import CoreGraphics

/// The split layout of a workspace's shown screen, for the hover card's miniature (``WorkspacePaneShapeView``):
/// each pane at its real share of the screen, its front tab's kind, and which pane has focus.
///
/// Leo 2026-11-22 (ask-890db939a2): "i dont think the shaped preview of the splits has merged/been written yet.
/// like, e.g. i have this layout. so. the preview should be able to depict that."
///
/// ```swift
/// let shape = SidebarPaneShape.split(axis: .horizontal, ratio: 0.5,
///                                    .pane(.init(kind: .browser, focused: true)),
///                                    .split(axis: .vertical, ratio: 0.5, .pane(.init(kind: .terminal)), .pane(.init(kind: .harness))))
/// shape.frames(in: CGRect(x: 0, y: 0, width: 200, height: 100), gap: 2).count // 3
/// ```
public nonisolated indirect enum SidebarPaneShape: Hashable, Sendable {
    /// How a split lays its two sides out.
    public enum Axis: Hashable, Sendable {
        /// Side by side: the first side on the left.
        case horizontal
        /// Stacked: the first side on top.
        case vertical
    }

    /// One pane of the shape.
    public struct Pane: Hashable, Sendable {
        /// The kind of the pane's front tab; nil for a pane with no tab yet.
        public var kind: SidebarWorkspaceKind?
        /// The pane the workspace's focus is in.
        public var focused: Bool

        public init(kind: SidebarWorkspaceKind?, focused: Bool = false) {
            self.kind = kind
            self.focused = focused
        }
    }

    case pane(Pane)
    /// `ratio` is the first side's share, kept within 0.05...0.95 so a side never draws empty.
    case split(axis: Axis, ratio: Double, SidebarPaneShape, SidebarPaneShape)
    /// Columns side by side at their widths' shares (a scrolling-columns screen).
    case row([Column])

    /// One column of a ``row(_:)``.
    public struct Column: Hashable, Sendable {
        /// Its share of the row against the other columns' widths.
        public var width: Double
        public var shape: SidebarPaneShape

        public init(width: Double, shape: SidebarPaneShape) {
            self.width = width
            self.shape = shape
        }
    }

    /// The panes it draws.
    public var paneCount: Int {
        switch self {
        case .pane: 1
        case let .split(_, _, a, b): a.paneCount + b.paneCount
        case let .row(columns): columns.reduce(0) { $0 + $1.shape.paneCount }
        }
    }

    /// Each pane's frame in `rect`, in depth-first order (left before right, top before bottom), `gap` points apart.
    /// `rect` is in a flipped space (y grows down), as AppKit's flipped views and Core Animation layers in them.
    public func frames(in rect: CGRect, gap: CGFloat) -> [(frame: CGRect, pane: Pane)] {
        var out: [(frame: CGRect, pane: Pane)] = []
        collect(in: rect, gap: gap, into: &out)
        return out
    }

    private func collect(in rect: CGRect, gap: CGFloat, into out: inout [(frame: CGRect, pane: Pane)]) {
        switch self {
        case let .pane(pane):
            out.append((rect, pane))
        case let .split(axis, ratio, a, b):
            let share = CGFloat(min(0.95, max(0.05, ratio)))
            switch axis {
            case .horizontal:
                let first = max(0, (rect.width - gap) * share)
                a.collect(in: CGRect(x: rect.minX, y: rect.minY, width: first, height: rect.height), gap: gap, into: &out)
                b.collect(in: CGRect(x: rect.minX + first + gap, y: rect.minY, width: max(0, rect.width - first - gap), height: rect.height),
                          gap: gap, into: &out)
            case .vertical:
                let first = max(0, (rect.height - gap) * share)
                a.collect(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first), gap: gap, into: &out)
                b.collect(in: CGRect(x: rect.minX, y: rect.minY + first + gap, width: rect.width, height: max(0, rect.height - first - gap)),
                          gap: gap, into: &out)
            }
        case let .row(columns):
            let total = columns.reduce(0) { $0 + max(0, $1.width) }
            guard total > 0 else { return }
            let usable = max(0, rect.width - gap * CGFloat(columns.count - 1))
            var x = rect.minX
            for column in columns {
                let width = usable * CGFloat(max(0, column.width) / total)
                column.shape.collect(in: CGRect(x: x, y: rect.minY, width: width, height: rect.height), gap: gap, into: &out)
                x += width + gap
            }
        }
    }
}
