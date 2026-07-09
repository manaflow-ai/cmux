import Foundation

extension RemoteTmuxWindowMirror {
    func clientGrid(contentSize: CGSize) -> (columns: Int, rows: Int)? {
        guard let geometry = currentGeometry() else { return nil }
        let appearance = bonsplitController.configuration.appearance
        return Self.clientGrid(
            layout: layout,
            contentSize: contentSize,
            cellSize: CGSize(
                width: CGFloat(geometry.cellWidthPx) / geometry.scale,
                height: CGFloat(geometry.cellHeightPx) / geometry.scale
            ),
            surfacePadding: CGSize(
                width: CGFloat(geometry.surfacePadWidthPx) / geometry.scale,
                height: CGFloat(geometry.surfacePadHeightPx) / geometry.scale
            ),
            tabBarHeight: appearance.tabBarHeight,
            dividerThickness: appearance.dividerThickness
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
        let chrome = chromeOverhead(
            layout: layout,
            surfacePadding: surfacePadding,
            tabBarHeight: tabBarHeight,
            dividerThickness: dividerThickness
        )
        let columns = Int((contentSize.width - chrome.width) / cellSize.width)
        let rows = Int((contentSize.height - chrome.height) / cellSize.height)
        return (max(20, columns), max(5, rows))
    }

    nonisolated static func chromeOverhead(
        layout: RemoteTmuxLayoutNode,
        surfacePadding: CGSize = .zero,
        tabBarHeight: CGFloat,
        dividerThickness: CGFloat
    ) -> CGSize {
        switch layout.content {
        case .pane:
            return CGSize(
                width: surfacePadding.width,
                height: tabBarHeight + surfacePadding.height
            )
        case .horizontal(let children):
            let childChrome = children.map {
                chromeOverhead(
                    layout: $0,
                    surfacePadding: surfacePadding,
                    tabBarHeight: tabBarHeight,
                    dividerThickness: dividerThickness
                )
            }
            return CGSize(
                width: childChrome.reduce(0) { $0 + $1.width }
                    + dividerThickness * CGFloat(max(0, children.count - 1)),
                height: childChrome.map(\.height).max() ?? 0
            )
        case .vertical(let children):
            let childChrome = children.map {
                chromeOverhead(
                    layout: $0,
                    surfacePadding: surfacePadding,
                    tabBarHeight: tabBarHeight,
                    dividerThickness: dividerThickness
                )
            }
            return CGSize(
                width: childChrome.map(\.width).max() ?? 0,
                height: childChrome.reduce(0) { $0 + $1.height }
                    + dividerThickness * CGFloat(max(0, children.count - 1))
            )
        }
    }

    nonisolated static func paneTitle(command: String?, cwd: String?) -> String? {
        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCommand.isEmpty,
           !RemoteTmuxPaneForegroundState.plainShellCommands.contains(trimmedCommand) {
            return trimmedCommand
        }
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCwd.isEmpty {
            let component = URL(fileURLWithPath: trimmedCwd).lastPathComponent
            if !component.isEmpty { return component }
        }
        return nil
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
