/// One terminal cell in retained-history coordinates.
public struct BackendTerminalCellPoint: Decodable, Equatable, Sendable {
    public let column: UInt32
    public let row: UInt64
}

/// Canonical selection bounds and text owned by the backend terminal.
public struct BackendTerminalSelection: Decodable, Equatable, Sendable {
    public struct Range: Decodable, Equatable, Sendable {
        public let start: BackendTerminalCellPoint
        public let end: BackendTerminalCellPoint
        public let topLeft: BackendTerminalCellPoint
        public let bottomRight: BackendTerminalCellPoint
        public let rectangle: Bool

        private enum CodingKeys: String, CodingKey {
            case start, end, rectangle
            case topLeft = "top_left"
            case bottomRight = "bottom_right"
        }
    }

    public let hasSelection: Bool
    /// Absent selections are encoded by the daemon with `text: null`.
    public let text: String?
    public let range: Range?

    private enum CodingKeys: String, CodingKey {
        case hasSelection = "has_selection"
        case text, range
    }
}

/// Canonical terminal cursor in retained-history coordinates.
public struct BackendTerminalCursorState: Decodable, Equatable, Sendable {
    public let column: UInt32
    public let row: UInt64
    public let visible: Bool
}

/// Canonical find state owned by the backend terminal.
public struct BackendTerminalSearchState: Decodable, Equatable, Sendable {
    public let active: Bool
    public let query: String
    public let selectedMatch: UInt64?
    public let totalMatches: UInt64

    private enum CodingKeys: String, CodingKey {
        case active, query
        case selectedMatch = "selected_match"
        case totalMatches = "total_matches"
    }
}

/// Canonical viewport position in retained-history rows.
public struct BackendTerminalViewportState: Decodable, Equatable, Sendable {
    public let totalRows: UInt64
    public let offset: UInt64
    public let visibleRows: UInt64

    private enum CodingKeys: String, CodingKey {
        case totalRows = "total_rows"
        case offset
        case visibleRows = "visible_rows"
    }
}

/// Coherent daemon-owned terminal UX state returned after every related mutation.
public struct BackendTerminalUXState: Decodable, Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let copyMode: Bool
    public let mouseTracking: Bool
    public let copyCursor: BackendTerminalCellPoint?
    public let cursor: BackendTerminalCursorState?
    public let selection: BackendTerminalSelection?
    public let search: BackendTerminalSearchState
    public let viewport: BackendTerminalViewportState

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_uuid"
        case copyMode = "copy_mode"
        case mouseTracking = "mouse_tracking"
        case copyCursor = "copy_cursor"
        case cursor, selection, search, viewport
    }
}

public struct BackendTerminalStateResponse: Decodable, Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let copyMode: Bool
    public let mouseTracking: Bool
    public let copyCursor: BackendTerminalCellPoint?
    public let cursor: BackendTerminalCursorState?
    public let selection: BackendTerminalSelection?
    public let search: BackendTerminalSearchState
    public let viewport: BackendTerminalViewportState

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_uuid"
        case copyMode = "copy_mode"
        case mouseTracking = "mouse_tracking"
        case copyCursor = "copy_cursor"
        case cursor, selection, search, viewport
    }

    public var state: BackendTerminalUXState {
        BackendTerminalUXState(
            surfaceID: surfaceID,
            copyMode: copyMode,
            mouseTracking: mouseTracking,
            copyCursor: copyCursor,
            cursor: cursor,
            selection: selection,
            search: search,
            viewport: viewport
        )
    }
}

public struct BackendTerminalActionResponse: Decodable, Equatable, Sendable {
    public let handled: Bool
    public let clipboardText: String?
    public let state: BackendTerminalUXState

    private enum CodingKeys: String, CodingKey {
        case handled
        case clipboardText = "clipboard_text"
        case state
    }
}

public struct BackendTerminalSelectionResponse: Decodable, Equatable, Sendable {
    public let selection: BackendTerminalSelection?
    public let state: BackendTerminalUXState
}

public enum BackendTerminalSelectionOperation: String, Sendable {
    case read
    case clear
    case selectAll = "select-all"
}

public enum BackendTerminalCopyModeOperation: String, Sendable {
    case enter
    case exit
    case startSelection = "start-selection"
    case startLineSelection = "start-line-selection"
    case clearSelection = "clear-selection"
    case adjust
    case copyAndExit = "copy-and-exit"
}

public enum BackendTerminalCopyModeAdjustment: String, Sendable {
    case left, right, up, down, home, end
    case pageUp = "page-up"
    case pageDown = "page-down"
    case beginningOfLine = "beginning-of-line"
    case endOfLine = "end-of-line"
}

public enum BackendTerminalSearchOperation: String, Sendable {
    case start, update, next, previous, end
}

public enum BackendTerminalScrollOperation: String, Sendable {
    case lines, pages, top, bottom
}
