import AppKit
import os

extension ScreenContentView {
    /// This screen's columns at their rest widths (``ColumnWidthLedger``).
    var restColumns: [ColumnWidthLedger.Column] {
        ColumnWidthLedger.columns(of: layout, in: baseGeometry, gap: context.style.stripGap, scale: scale)
    }
}

/// Counts and logs R3b violations (``ColumnWidthLedger``): the App's `SurfaceInvariantMonitor` runs it once
/// the layout settles, in debug builds only (release builds record no widths, so it finds nothing). One
/// violation per create that resized another column, logged with each such column's old and new width.
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
            for (id, screen) in root.screenViews.sorted(by: { $0.key < $1.key }) where screen.columnWidths.record != nil {
                // Hidden before its check (a screen switch): the record would blame a later change.
                guard !screen.isHidden else { screen.columnWidths.drop(); continue }
                let changes = screen.columnWidths.take(screen.restColumns, viewportWidth: screen.bounds.width)
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
