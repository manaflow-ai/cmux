public import CMUXMobileCore

/// The slice of one authoritative render-grid frame that echo prediction
/// reconciles against.
///
/// The engine never touches the full frame DTO; this summary keeps the state
/// machine pure and cheap to construct in tests. `coveredRows` distinguishes
/// rows the frame authoritatively states (full frames state every row; deltas
/// state cleared rows plus rows with spans) from rows it says nothing about,
/// so a delta cannot falsely contradict a prediction on an untouched row.
public struct MobileEchoAuthoritativeUpdate: Equatable, Sendable {
    /// DEC private mouse-tracking modes; any of them on means a TUI owns the
    /// primary screen and echo prediction is unsafe.
    public static let mouseTrackingModeCodes: Set<Int> = [1000, 1001, 1002, 1003]

    public var stateSeq: UInt64
    public var isFull: Bool
    public var activeScreen: MobileTerminalRenderGridFrame.Screen
    public var columns: Int
    public var rows: Int
    /// Authoritative cursor, or `nil` when the frame carried none (keep the
    /// previously known cursor).
    public var cursorRow: Int?
    public var cursorColumn: Int?
    public var cursorVisible: Bool
    /// Whether any mouse-tracking mode is set. Only meaningful when
    /// `modesAuthoritative`; delta frames strip mode state.
    public var mouseTrackingActive: Bool
    /// Full frames carry the complete mode list; deltas keep only autowrap, so
    /// consumers must not clear TUI signals from a delta.
    public var modesAuthoritative: Bool
    /// Rows the producer pushed into scrollback since the previous frame.
    /// Outstanding predictions shift up by this amount before content is judged.
    public var scrolledRows: Int
    /// Viewport rows whose content this update authoritatively states.
    public var coveredRows: Set<Int>
    /// Grid-aligned plain text for covered rows; a missing entry is a blank row.
    public var rowTexts: [Int: String]

    public init(
        stateSeq: UInt64,
        isFull: Bool,
        activeScreen: MobileTerminalRenderGridFrame.Screen,
        columns: Int,
        rows: Int,
        cursorRow: Int?,
        cursorColumn: Int?,
        cursorVisible: Bool,
        mouseTrackingActive: Bool,
        modesAuthoritative: Bool,
        scrolledRows: Int,
        coveredRows: Set<Int>,
        rowTexts: [Int: String]
    ) {
        self.stateSeq = stateSeq
        self.isFull = isFull
        self.activeScreen = activeScreen
        self.columns = columns
        self.rows = rows
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible
        self.mouseTrackingActive = mouseTrackingActive
        self.modesAuthoritative = modesAuthoritative
        self.scrolledRows = scrolledRows
        self.coveredRows = coveredRows
        self.rowTexts = rowTexts
    }

    /// Summarizes a delivered render-grid frame.
    public init(frame: MobileTerminalRenderGridFrame) {
        let covered: Set<Int>
        if frame.full {
            covered = Set(0..<frame.rows)
        } else {
            covered = Set(frame.clearedRows).union(frame.rowSpans.map(\.row))
        }
        var rowTexts: [Int: String] = [:]
        let plainRows = frame.plainRows()
        for row in covered where plainRows.indices.contains(row) {
            let text = plainRows[row]
            if !text.isEmpty {
                rowTexts[row] = text
            }
        }
        self.init(
            stateSeq: frame.stateSeq,
            isFull: frame.full,
            activeScreen: frame.activeScreen,
            columns: frame.columns,
            rows: frame.rows,
            cursorRow: frame.cursor?.row,
            cursorColumn: frame.cursor?.column,
            cursorVisible: frame.cursor?.visible ?? true,
            mouseTrackingActive: frame.modes.contains { mode in
                !mode.ansi && mode.on && Self.mouseTrackingModeCodes.contains(mode.code)
            },
            modesAuthoritative: frame.full,
            scrolledRows: frame.scrolledRows,
            coveredRows: covered,
            rowTexts: rowTexts
        )
    }

    /// The character the update states for a covered cell (blank when the row
    /// text ends before the column).
    public func character(atRow row: Int, column: Int) -> Character? {
        guard coveredRows.contains(row) else { return nil }
        guard let text = rowTexts[row] else { return " " }
        guard column >= 0, column < text.count else { return " " }
        return text[text.index(text.startIndex, offsetBy: column)]
    }

    /// Whether a covered row can be judged by column arithmetic. A row holding
    /// non-ASCII content may contain double-width cells, which break the
    /// column-to-character mapping, so predictions on it are unjudgeable.
    public func rowIsColumnAddressable(_ row: Int) -> Bool {
        guard let text = rowTexts[row] else { return true }
        return text.unicodeScalars.allSatisfy { $0.isASCII }
    }
}
