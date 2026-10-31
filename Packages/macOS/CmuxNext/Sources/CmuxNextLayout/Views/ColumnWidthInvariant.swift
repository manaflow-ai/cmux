import AppKit
import os

extension ScreenContentView {
    /// This screen at its rest frames (``ColumnWidthLedger``).
    var restShape: ColumnWidthLedger.Shape { ColumnWidthLedger.shape(of: layout, in: baseGeometry) }
}

/// Counts and logs R3b violations (``ColumnWidthLedger``): the App's `SurfaceInvariantMonitor` runs it once
/// the layout settles, in debug builds only (release builds record no widths, so it finds nothing). One
/// violation per create that resized an existing pane, logged with each one's column and old and new width.
@MainActor
public final class ColumnWidthInvariant {
    public private(set) var violations = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.surfaces")

    public init() {}

    /// Compares each shown screen's recorded widths with its widths now. `action`: the newest action, for the log.
    /// - Returns: The violations this check found.
    @discardableResult
    public func check(_ roots: [LayoutRootView], action: String) -> Int {
        var found = 0
        for root in roots {
            for (id, screen) in root.screenViews.sorted(by: { $0.key < $1.key }) where !screen.isHidden && screen.columnWidths.record != nil {
                let changes = screen.columnWidths.take(screen.restShape, viewportWidth: screen.bounds.width)
                guard !changes.isEmpty else { continue }
                found += 1
                let text = changes.map(\.description).joined(separator: ", ")
                #if DEBUG
                logger.fault("column width invariant: screen \(id.rawValue, privacy: .public) resized \(text, privacy: .public) after \(action, privacy: .public)")
                #else
                logger.error("column width invariant: screen \(id.rawValue, privacy: .public) resized \(text, privacy: .public) after \(action, privacy: .public)")
                #endif
            }
        }
        violations += found
        return found
    }
}
