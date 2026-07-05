import Foundation

struct RemoteTmuxMirrorLayoutMath {
    static func clientGrid(
        layout: RemoteTmuxLayoutNode,
        contentSize: CGSize,
        cellSize: CGSize,
        tabBarHeight: CGFloat,
        dividerThickness: CGFloat
    ) -> (columns: Int, rows: Int)? {
        guard contentSize.width > 1, contentSize.height > 1,
              cellSize.width > 1, cellSize.height > 1 else { return nil }
        let chrome = chromeOverhead(
            layout: layout,
            tabBarHeight: tabBarHeight,
            dividerThickness: dividerThickness
        )
        let cols = Int((contentSize.width - chrome.width) / cellSize.width)
        let rows = Int((contentSize.height - chrome.height) / cellSize.height)
        return (max(20, cols), max(5, rows))
    }

    static func chromeOverhead(
        layout: RemoteTmuxLayoutNode,
        tabBarHeight: CGFloat,
        dividerThickness: CGFloat
    ) -> CGSize {
        switch layout.content {
        case .pane:
            return CGSize(width: 0, height: tabBarHeight)
        case .horizontal(let children):
            let child = children.map {
                chromeOverhead(layout: $0, tabBarHeight: tabBarHeight, dividerThickness: dividerThickness)
            }
            return CGSize(
                width: child.reduce(0) { $0 + $1.width } + dividerThickness * CGFloat(max(0, children.count - 1)),
                height: child.map(\.height).max() ?? 0
            )
        case .vertical(let children):
            let child = children.map {
                chromeOverhead(layout: $0, tabBarHeight: tabBarHeight, dividerThickness: dividerThickness)
            }
            return CGSize(
                width: child.map(\.width).max() ?? 0,
                height: child.reduce(0) { $0 + $1.height } + dividerThickness * CGFloat(max(0, children.count - 1))
            )
        }
    }

    static func paneTitle(command: String?, cwd: String?) -> String? {
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

    static func dividerFraction(
        first: RemoteTmuxLayoutNode,
        rest: [RemoteTmuxLayoutNode],
        horizontal: Bool
    ) -> CGFloat {
        let firstSpan = horizontal ? first.width : first.height
        let restSpan = rest.reduce(0) { $0 + (horizontal ? $1.width : $1.height) }
            + max(0, rest.count - 1)
        return CGFloat(firstSpan) / CGFloat(max(1, firstSpan + restSpan + 1))
    }

    static func sameShapeAndPaneIds(_ lhs: RemoteTmuxLayoutNode, _ rhs: RemoteTmuxLayoutNode) -> Bool {
        switch (lhs.content, rhs.content) {
        case (.pane(let left), .pane(let right)):
            return left == right
        case (.horizontal(let left), .horizontal(let right)), (.vertical(let left), .vertical(let right)):
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { sameShapeAndPaneIds($0, $1) }
        default:
            return false
        }
    }
}
