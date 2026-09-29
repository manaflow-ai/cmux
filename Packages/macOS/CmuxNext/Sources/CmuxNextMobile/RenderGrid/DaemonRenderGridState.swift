public import CMUXMobileCore
public import Foundation

/// The phone-visible viewport of one daemon render attach, kept current by
/// applying `render-state` and `render-delta` events, and exported as the
/// shipped iOS `cmux.render-grid.v1` frame.
///
/// Every export is a full frame with a strictly increasing revision in one
/// epoch per attach, so the phone's continuity check never needs a delta
/// base. Known gap versus the old Mac-rendered grid: daemon render mode does
/// not report the active screen or DEC/ANSI modes (application cursor keys,
/// bracketed paste, mouse tracking), so frames always say `primary` with no
/// modes. The byte-mode compat path (vt-state replay) carries them.
public struct DaemonRenderGridState: Sendable {
    public let surfaceID: String
    public let renderEpoch: String
    public private(set) var columns = 0
    public private(set) var rowCount = 0
    public private(set) var revision: UInt64 = 0
    private var rows: [[DaemonRenderFrame.Run]] = []
    private var cursor: DaemonRenderFrame.Cursor?
    private var defaultFG: String?
    private var defaultBG: String?

    public init(surfaceID: String, renderEpoch: String = UUID().uuidString) {
        self.surfaceID = surfaceID
        self.renderEpoch = renderEpoch
    }

    /// Whether a complete viewport has been received.
    public var hasViewport: Bool { columns > 0 && rowCount > 0 }

    /// Applies one render event. Returns false for a delta that arrives
    /// before any complete viewport (the caller re-attaches).
    @discardableResult
    public mutating func apply(_ frame: DaemonRenderFrame) -> Bool {
        if let size = frame.size {
            columns = max(1, size.cols)
            rowCount = max(1, size.rows)
        }
        if frame.isComplete {
            guard columns > 0, rowCount > 0 else { return false }
            rows = Array(repeating: [], count: rowCount)
        } else if !hasViewport {
            return false
        }
        for row in frame.rows where row.row >= 0 && row.row < rowCount {
            rows[row.row] = row.runs
        }
        cursor = frame.cursor
        if let fg = frame.defaultFG { defaultFG = fg }
        if let bg = frame.defaultBG { defaultBG = bg }
        revision += 1
        return true
    }

    /// The current viewport as a full render-grid frame. `stateSeq` is the
    /// caller's monotonic output sequence for this surface.
    public func frame(stateSeq: UInt64) throws -> MobileTerminalRenderGridFrame {
        var styles = DaemonRenderStyleTable()
        var spans: [MobileTerminalRenderGridFrame.RowSpan] = []
        for (rowIndex, runs) in rows.enumerated() {
            var column = 0
            for run in runs {
                let width = run.cellWidth
                defer { column += width }
                guard width > 0, column < columns else { continue }
                let styleID = styles.id(for: run)
                // Full frames start from a cleared screen: blank default cells need no span.
                if styleID == 0, run.text.allSatisfy({ $0 == " " }) { continue }
                let clipped = min(width, columns - column)
                spans.append(.init(row: rowIndex, column: column, styleID: styleID,
                                   text: run.text, cellWidth: clipped))
            }
        }
        return try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderEpoch: renderEpoch,
            renderRevision: revision,
            columns: columns,
            rows: rowCount,
            cursor: gridCursor(),
            full: true,
            styles: styles.styles,
            rowSpans: spans,
            terminalForeground: defaultFG,
            terminalBackground: defaultBG,
            terminalCursorColor: cursor?.color
        )
    }

    private func gridCursor() -> MobileTerminalRenderGridFrame.Cursor? {
        guard let cursor else { return nil }
        let style: MobileTerminalRenderGridFrame.Cursor.Style = switch cursor.style {
        case "bar": .bar
        case "underline": .underline
        default: .block
        }
        // The daemon zeroes coordinates it cannot expose; the grid validates
        // bounds even for a hidden cursor, so clamp.
        return .init(row: min(max(0, cursor.y), rowCount - 1),
                     column: min(max(0, cursor.x), columns - 1),
                     visible: cursor.visible, style: style, blinking: cursor.blink)
    }
}
