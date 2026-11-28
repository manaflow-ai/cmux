public import CoreGraphics
import Foundation

/// `debug.dock`'s rows as `JSONSerialization` objects (the app bridges them with `JSONValue(foundation:)`), kept next
/// to the values they read so the socket handler in CmuxNextApp stays wiring.
extension WindowDocks {
    /// One row per edge dock of `window`, hidden or drawn: window, edge, workspace, mode, hidden. A probe reads
    /// Show/Hide Dock from it.
    public func debugRows(window: String) -> [[String: Any]] {
        all.map { dock in
            ["window": window, "edge": dock.edge.rawValue, "workspace": dock.workspace,
             "mode": dock.mode.rawValue, "hidden": dock.hidden]
        }
    }
}

extension DockLayoutReport {
    /// One row per docked column of the window's active screen: where it is and where its rim (inner-edge resize
    /// handle) is, in window coordinates.
    public func debugColumns(window: String) -> [[String: Any]] {
        columns.map { column in
            ["window": window, "column": column.column.rawValue, "edge": column.dock.edge.rawValue,
             "mode": column.dock.mode.rawValue, "shown": column.shownAsDock,
             "frame_in_window": Self.debugRect(column.frameInWindow),
             "rim_in_window": column.rimInWindow.map(Self.debugRect) ?? NSNull()]
        }
    }

    /// A rect as `x`, `y`, `width`, `height`.
    public static func debugRect(_ rect: CGRect) -> [String: Any] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
