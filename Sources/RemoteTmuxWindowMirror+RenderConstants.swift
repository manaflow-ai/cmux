import AppKit

extension RemoteTmuxWindowMirror {

    /// Divider-strip thickness for the TRANSIENT render, matching the cell
    /// rows/columns tmux allocates to separators and title rows — so the
    /// drag-time chrome occupies exactly the space the imposed render's
    /// strips do and the mode switch is seamless. Falls back to a thin gap
    /// while the render constants are still unknown.
    var stripRowHeightPt: CGFloat {
        guard let geometry = currentGeometry() else { return 2 }
        return CGFloat(geometry.cellHeightPx) / max(1, geometry.scale)
    }


    var stripColumnWidthPt: CGFloat {
        guard let geometry = currentGeometry() else { return 2 }
        return CGFloat(geometry.cellWidthPx) / max(1, geometry.scale)
    }

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
