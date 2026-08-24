import CmuxRemoteSession
import Bonsplit
import Foundation

extension SplitOrientation {
    var remoteTmuxOrientation: RemoteTmuxSplitOrientation {
        self == .horizontal ? .horizontal : .vertical
    }

    var treeName: String {
        self == .horizontal ? "horizontal" : "vertical"
    }
}

extension RemoteTmuxWindowMirror {
    func clientGrid(contentSize: CGSize) -> (columns: Int, rows: Int)? {
        nativeLayoutMetrics()?.clientGrid(layout: layout, contentSize: contentSize)
    }

    func nativeLayoutMetrics() -> RemoteTmuxNativeLayoutMetrics? {
        guard let geometry = currentGeometry() else { return nil }
        let appearance = bonsplitController.configuration.appearance
        return RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(
                width: CGFloat(geometry.cellWidthPx) / geometry.scale,
                height: CGFloat(geometry.cellHeightPx) / geometry.scale
            ),
            surfacePadding: CGSize(
                width: CGFloat(geometry.surfacePadWidthPx) / geometry.scale,
                height: CGFloat(geometry.surfacePadHeightPx) / geometry.scale
            ),
            tabBarHeight: appearance.tabBarHeight,
            dividerThickness: appearance.dividerThickness,
            paneTitleRowHeight: tmuxTitleRowPlacement != nil
                ? CGFloat(geometry.cellHeightPx) / geometry.scale
                : 0,
            minimumPaneExtent: RemoteTmuxNativeLayoutMetrics.bonsplitMinimumPaneExtent,
            paneTitleRowPaneIDs: tmuxTitleRowPlacement?.paneIDs(in: renderedLayout) ?? []
        )
    }

    nonisolated static func clientGrid(
        layout: RemoteTmuxLayoutNode,
        contentSize: CGSize,
        cellSize: CGSize,
        surfacePadding: CGSize = .zero,
        tabBarHeight: CGFloat,
        dividerThickness: CGFloat
    ) -> (columns: Int, rows: Int)? {
        guard contentSize.width > 1, contentSize.height > 1,
              cellSize.width > 1, cellSize.height > 1 else { return nil }
        return RemoteTmuxNativeLayoutMetrics(
            cellSize: cellSize,
            surfacePadding: surfacePadding,
            tabBarHeight: tabBarHeight,
            dividerThickness: dividerThickness
        ).clientGrid(layout: layout, contentSize: contentSize)
    }

    nonisolated static func windowPaneTitle(_ windowTitle: String, paneIndex: Int) -> String {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty
            ? String(localized: "remoteTmux.tab.window", defaultValue: "tmux window")
            : trimmed
        guard paneIndex > 0 else { return base }
        let formattedIndex = paneIndex.formatted()
        return String(
            localized: "remoteTmux.tab.windowPaneIndexed",
            defaultValue: "\(base) [\(formattedIndex)]"
        )
    }

    nonisolated static func dividerFraction(
        first: RemoteTmuxLayoutNode,
        rest: [RemoteTmuxLayoutNode],
        horizontal: Bool
    ) -> CGFloat {
        let firstSpan = horizontal ? first.width : first.height
        let restSpan = rest.reduce(0) { $0 + (horizontal ? $1.width : $1.height) }
            + max(0, rest.count - 1)
        return CGFloat(firstSpan) / CGFloat(max(1, firstSpan + restSpan + 1))
    }

    func nativeDividerFraction(
        first: RemoteTmuxLayoutNode,
        rest: [RemoteTmuxLayoutNode],
        orientation: SplitOrientation
    ) -> CGFloat {
        nativeLayoutMetrics()?.dividerFraction(
            first: first,
            rest: rest,
            orientation: orientation.remoteTmuxOrientation
        ) ?? Self.dividerFraction(
            first: first,
            rest: rest,
            horizontal: orientation == .horizontal
        )
    }

    nonisolated static func sameShapeAndPaneIds(
        _ lhs: RemoteTmuxLayoutNode,
        _ rhs: RemoteTmuxLayoutNode
    ) -> Bool {
        switch (lhs.content, rhs.content) {
        case (.pane(let left), .pane(let right)):
            return left == right
        case (.horizontal(let left), .horizontal(let right)),
             (.vertical(let left), .vertical(let right)):
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { sameShapeAndPaneIds($0, $1) }
        default:
            return false
        }
    }

    /// The split-tree shape (node kinds plus pane ids), excluding geometry.
    /// Geometry-only reflows keep this signature stable; pane and nesting
    /// changes invalidate it and re-arm client sizing.
    nonisolated static func structureSignature(of node: RemoteTmuxLayoutNode) -> String {
        switch node.content {
        case let .pane(paneId):
            return "p\(paneId)"
        case let .horizontal(children):
            return "h(" + children.map(structureSignature(of:)).joined(separator: ",") + ")"
        case let .vertical(children):
            return "v(" + children.map(structureSignature(of:)).joined(separator: ",") + ")"
        }
    }
}
