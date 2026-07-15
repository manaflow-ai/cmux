public import Foundation

/// A value snapshot of a workspace's split-pane layout.
public struct MobilePaneLayout: Sendable, Equatable {
    /// A node in the recursive pane layout tree.
    public indirect enum Node: Sendable, Equatable {
        /// A branch that divides its rectangle between two child nodes.
        case split(MobilePaneSplit)
        /// A leaf pane containing an ordered set of surfaces.
        case pane(MobilePaneNode)
    }

    /// The Mac-side pane layout version associated with this snapshot.
    public let version: Int
    /// The focused pane identifier, when the Mac reports one.
    public let focusedPaneID: String?
    /// The root of the recursive split-pane tree.
    public let root: Node

    /// Creates a pane layout snapshot.
    /// - Parameters:
    ///   - version: The Mac-side pane layout version.
    ///   - focusedPaneID: The focused pane identifier, when known.
    ///   - root: The root of the recursive split-pane tree.
    public init(version: Int, focusedPaneID: String?, root: Node) {
        self.version = version
        self.focusedPaneID = focusedPaneID
        self.root = root
    }

    /// The layout's panes in depth-first, first-child-then-second-child order.
    public var orderedPanes: [MobilePaneNode] {
        var panes: [MobilePaneNode] = []
        Self.appendPanes(in: root, to: &panes)
        return panes
    }

    /// Finds the pane containing a surface.
    /// - Parameter surfaceID: The stable surface identifier to find.
    /// - Returns: The containing pane, or `nil` when the surface is absent.
    public func pane(containing surfaceID: String) -> MobilePaneNode? {
        orderedPanes.first { pane in
            pane.surfaces.contains { $0.id == surfaceID }
        }
    }

    /// Computes pane rectangles in unit space without applying a gutter.
    /// - Returns: A dictionary from pane identifier to its rectangle in the `0...1` unit square.
    public func normalizedRects() -> [String: CGRect] {
        var rects: [String: CGRect] = [:]
        Self.appendNormalizedRects(
            for: root,
            in: CGRect(x: 0, y: 0, width: 1, height: 1),
            to: &rects
        )
        return rects
    }

    private static func appendPanes(in node: Node, to panes: inout [MobilePaneNode]) {
        switch node {
        case let .split(split):
            appendPanes(in: split.first, to: &panes)
            appendPanes(in: split.second, to: &panes)
        case let .pane(pane):
            panes.append(pane)
        }
    }

    private static func appendNormalizedRects(
        for node: Node,
        in rect: CGRect,
        to rects: inout [String: CGRect]
    ) {
        switch node {
        case let .pane(pane):
            rects[pane.id] = rect
        case let .split(split):
            let ratio = CGFloat(split.ratio)
            let firstRect: CGRect
            let secondRect: CGRect
            switch split.orientation {
            case .horizontal:
                let firstWidth = rect.width * ratio
                firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: firstWidth,
                    height: rect.height
                )
                secondRect = CGRect(
                    x: rect.minX + firstWidth,
                    y: rect.minY,
                    width: rect.width - firstWidth,
                    height: rect.height
                )
            case .vertical:
                let firstHeight = rect.height * ratio
                firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: firstHeight
                )
                secondRect = CGRect(
                    x: rect.minX,
                    y: rect.minY + firstHeight,
                    width: rect.width,
                    height: rect.height - firstHeight
                )
            }
            appendNormalizedRects(for: split.first, in: firstRect, to: &rects)
            appendNormalizedRects(for: split.second, in: secondRect, to: &rects)
        }
    }
}
