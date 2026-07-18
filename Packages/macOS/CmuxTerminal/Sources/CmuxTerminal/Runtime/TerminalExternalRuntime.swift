public import Foundation

/// A stable description of the Swift presentation attached to a persistent terminal.
public struct TerminalExternalPresentation: Equatable, Sendable {
    public let surfaceID: UUID
    public let workspaceID: UUID

    public init(surfaceID: UUID, workspaceID: UUID) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
    }
}

/// A thread-safe, idempotent presentation attachment.
///
/// `TerminalSurface.deinit` is intentionally nonisolated. Keeping detach on a
/// small Sendable lease lets deinit synchronously release renderer/presentation
/// ownership without asking the persistent runtime to close its PTY.
public protocol TerminalExternalPresentationLease: AnyObject, Sendable {
    nonisolated func detach()
}

/// The persistent terminal's last observed lifecycle state.
public enum TerminalExternalRuntimeLifecycle: Equatable, Sendable {
    case live
    case processExited
    case unavailable
}

/// Cached process metadata supplied by the persistent owner of the PTY.
public struct TerminalExternalProcessMetadata: Equatable, Sendable {
    public let foregroundProcessID: Int?
    public let controllingTTYName: String?

    public init(foregroundProcessID: Int?, controllingTTYName: String?) {
        self.foregroundProcessID = foregroundProcessID
        self.controllingTTYName = controllingTTYName
    }
}

/// A daemon-projected range in AppKit's UTF-16 coordinate space.
public struct TerminalAccessibilityRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// One terminal grid cell mapped to flattened accessibility text.
public struct TerminalAccessibilityCell: Equatable, Sendable {
    public let column: Int
    public let columnSpan: Int
    public let utf16Range: TerminalAccessibilityRange

    public init(column: Int, columnSpan: Int, utf16Range: TerminalAccessibilityRange) {
        self.column = column
        self.columnSpan = columnSpan
        self.utf16Range = utf16Range
    }
}

/// One visible terminal row with exact cell and UTF-16 coordinates.
public struct TerminalAccessibilityLine: Equatable, Sendable {
    public let row: UInt64
    public let utf16Range: TerminalAccessibilityRange
    public let cells: [TerminalAccessibilityCell]

    public init(
        row: UInt64,
        utf16Range: TerminalAccessibilityRange,
        cells: [TerminalAccessibilityCell]
    ) {
        self.row = row
        self.utf16Range = utf16Range
        self.cells = cells
    }
}

/// Canonical cursor and insertion position inside the visible value.
public struct TerminalAccessibilityCursor: Equatable, Sendable {
    public let column: Int
    public let row: UInt64
    public let insertionRange: TerminalAccessibilityRange
    public let line: Int

    public init(
        column: Int,
        row: UInt64,
        insertionRange: TerminalAccessibilityRange,
        line: Int
    ) {
        self.column = column
        self.row = row
        self.insertionRange = insertionRange
        self.line = line
    }
}

/// Canonical selection text and visible range intersections.
public struct TerminalAccessibilitySelection: Equatable, Sendable {
    public let text: String
    public let utf16Ranges: [TerminalAccessibilityRange]

    public init(text: String, utf16Ranges: [TerminalAccessibilityRange]) {
        self.text = text
        self.utf16Ranges = utf16Ranges
    }
}

/// A revision-fenced OSC 8 link exposed as an AX link child.
public struct TerminalAccessibilityLink: Equatable, Sendable {
    public let id: String
    public let target: String
    public let utf16Range: TerminalAccessibilityRange
    public let row: UInt64
    public let startColumn: Int
    public let endColumn: Int

    public init(
        id: String,
        target: String,
        utf16Range: TerminalAccessibilityRange,
        row: UInt64,
        startColumn: Int,
        endColumn: Int
    ) {
        self.id = id
        self.target = target
        self.utf16Range = utf16Range
        self.row = row
        self.startColumn = startColumn
        self.endColumn = endColumn
    }
}

/// Revisioned daemon-owned accessibility state for one rendered presentation.
public struct TerminalAccessibilitySnapshot: Equatable, Sendable {
    public let schemaVersion: UInt32
    public let surfaceID: UUID
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let contentSequence: UInt64
    public let terminalRevision: UInt64
    public let contentRevision: UInt64
    public let viewportRevision: UInt64
    public let viewportOffset: UInt64
    public let columns: Int
    public let rows: Int
    public let text: String
    public let lines: [TerminalAccessibilityLine]
    public let cursor: TerminalAccessibilityCursor?
    public let selections: [TerminalAccessibilitySelection]
    public let links: [TerminalAccessibilityLink]
    public let focused: Bool

    public init(
        schemaVersion: UInt32,
        surfaceID: UUID,
        presentationID: UUID,
        presentationGeneration: UInt64,
        contentSequence: UInt64,
        terminalRevision: UInt64,
        contentRevision: UInt64,
        viewportRevision: UInt64,
        viewportOffset: UInt64,
        columns: Int,
        rows: Int,
        text: String,
        lines: [TerminalAccessibilityLine],
        cursor: TerminalAccessibilityCursor?,
        selections: [TerminalAccessibilitySelection],
        links: [TerminalAccessibilityLink],
        focused: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.surfaceID = surfaceID
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.contentSequence = contentSequence
        self.terminalRevision = terminalRevision
        self.contentRevision = contentRevision
        self.viewportRevision = viewportRevision
        self.viewportOffset = viewportOffset
        self.columns = columns
        self.rows = rows
        self.text = text
        self.lines = lines
        self.cursor = cursor
        self.selections = selections
        self.links = links
        self.focused = focused
    }
}

/// Cached grid and glyph metrics supplied by the out-of-process renderer.
public struct TerminalExternalCellMetrics: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cellWidthPixels: Int
    public let cellHeightPixels: Int
    public let surfaceWidthPixels: Int
    public let surfaceHeightPixels: Int
    public let backingScale: Double

    public init(
        columns: Int,
        rows: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int,
        surfaceWidthPixels: Int,
        surfaceHeightPixels: Int,
        backingScale: Double
    ) {
        self.columns = columns
        self.rows = rows
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
        self.surfaceWidthPixels = surfaceWidthPixels
        self.surfaceHeightPixels = surfaceHeightPixels
        self.backingScale = backingScale
    }
}

/// A coherent cached read of external runtime state.
public struct TerminalExternalRuntimeSnapshot: Equatable, Sendable {
    public let lifecycle: TerminalExternalRuntimeLifecycle
    public let visibleText: String?
    public let cellMetrics: TerminalExternalCellMetrics?
    public let processMetadata: TerminalExternalProcessMetadata?
    public let needsCloseConfirmation: Bool
    public let copyModeActive: Bool
    public let mouseTracking: Bool
    public let copyCursor: TerminalExternalCellPoint?
    public let cursor: TerminalExternalCursorState?
    public let selection: TerminalExternalSelection?
    public let search: TerminalExternalSearchState?
    public let viewportState: TerminalExternalViewportState?
    public let accessibility: TerminalAccessibilitySnapshot?

    public init(
        lifecycle: TerminalExternalRuntimeLifecycle,
        visibleText: String? = nil,
        cellMetrics: TerminalExternalCellMetrics? = nil,
        processMetadata: TerminalExternalProcessMetadata? = nil,
        needsCloseConfirmation: Bool = false,
        copyModeActive: Bool = false,
        mouseTracking: Bool = false,
        copyCursor: TerminalExternalCellPoint? = nil,
        cursor: TerminalExternalCursorState? = nil,
        selection: TerminalExternalSelection? = nil,
        search: TerminalExternalSearchState? = nil,
        viewportState: TerminalExternalViewportState? = nil,
        accessibility: TerminalAccessibilitySnapshot? = nil
    ) {
        self.lifecycle = lifecycle
        self.visibleText = visibleText
        self.cellMetrics = cellMetrics
        self.processMetadata = processMetadata
        self.needsCloseConfirmation = needsCloseConfirmation
        self.copyModeActive = copyModeActive
        self.mouseTracking = mouseTracking
        self.copyCursor = copyCursor
        self.cursor = cursor
        self.selection = selection
        self.search = search
        self.viewportState = viewportState
        self.accessibility = accessibility
    }
}

/// One terminal cell in backend-owned retained-history coordinates.
public struct TerminalExternalCellPoint: Equatable, Sendable {
    public let column: UInt32
    public let row: UInt64

    public init(column: UInt32, row: UInt64) {
        self.column = column
        self.row = row
    }
}

/// Cached canonical cursor used to position AppKit IME candidate windows.
public struct TerminalExternalCursorState: Equatable, Sendable {
    public let column: UInt32
    public let row: UInt64
    public let visible: Bool

    public init(column: UInt32, row: UInt64, visible: Bool) {
        self.column = column
        self.row = row
        self.visible = visible
    }
}

/// A canonical terminal selection and its text.
public struct TerminalExternalSelection: Equatable, Sendable {
    public let text: String
    public let start: TerminalExternalCellPoint
    public let end: TerminalExternalCellPoint
    public let topLeft: TerminalExternalCellPoint
    public let bottomRight: TerminalExternalCellPoint
    public let rectangle: Bool

    public init(
        text: String,
        start: TerminalExternalCellPoint,
        end: TerminalExternalCellPoint,
        topLeft: TerminalExternalCellPoint,
        bottomRight: TerminalExternalCellPoint,
        rectangle: Bool
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.topLeft = topLeft
        self.bottomRight = bottomRight
        self.rectangle = rectangle
    }
}

/// Cached canonical search state used by the Swift find overlay.
public struct TerminalExternalSearchState: Equatable, Sendable {
    public let active: Bool
    public let query: String
    public let selectedMatch: UInt64?
    public let totalMatches: UInt64

    public init(active: Bool, query: String, selectedMatch: UInt64?, totalMatches: UInt64) {
        self.active = active
        self.query = query
        self.selectedMatch = selectedMatch
        self.totalMatches = totalMatches
    }
}

/// Cached canonical scrollback viewport state.
public struct TerminalExternalViewportState: Equatable, Sendable {
    public let totalRows: UInt64
    public let offset: UInt64
    public let visibleRows: UInt64

    public init(totalRows: UInt64, offset: UInt64, visibleRows: UInt64) {
        self.totalRows = totalRows
        self.offset = offset
        self.visibleRows = visibleRows
    }
}

/// The origin of terminal text, kept separate so the backend can preserve
/// bracketed-paste and committed-text semantics.
public enum TerminalExternalTextKind: Equatable, Sendable {
    case committed
    case paste
    case automation
}

/// Text accepted by the canonical terminal owner.
public struct TerminalExternalTextInput: Equatable, Sendable {
    public let text: String
    public let kind: TerminalExternalTextKind

    public init(text: String, kind: TerminalExternalTextKind) {
        self.text = text
        self.kind = kind
    }
}

/// Stable key modifiers, independent of AppKit and libghostty C types.
public struct TerminalExternalKeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let capsLock = Self(rawValue: 1 << 4)
    public static let numLock = Self(rawValue: 1 << 5)
    public static let rightShift = Self(rawValue: 1 << 6)
    public static let rightControl = Self(rawValue: 1 << 7)
    public static let rightOption = Self(rawValue: 1 << 8)
    public static let rightCommand = Self(rawValue: 1 << 9)
}

/// The phase of a physical key event.
public enum TerminalExternalKeyAction: Equatable, Sendable {
    case press
    case release
    case `repeat`
}

/// A semantic physical-key event for the persistent terminal owner.
///
/// `key` is the stable numeric Ghostty/W3C key enum. AppKit virtual keycodes
/// must be translated at the view boundary before constructing this DTO.
public struct TerminalExternalKeyEvent: Equatable, Sendable {
    public let key: UInt32
    public let modifiers: TerminalExternalKeyModifiers
    public let consumedModifiers: TerminalExternalKeyModifiers
    public let text: String?
    public let unshiftedCodepoint: UInt32
    public let action: TerminalExternalKeyAction

    public init(
        key: UInt32,
        modifiers: TerminalExternalKeyModifiers = [],
        consumedModifiers: TerminalExternalKeyModifiers = [],
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0,
        action: TerminalExternalKeyAction = .press
    ) {
        self.key = key
        self.modifiers = modifiers
        self.consumedModifiers = consumedModifiers
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
        self.action = action
    }
}

/// One input operation accepted by the external runtime's ordered ingress.
public enum TerminalExternalInput: Equatable, Sendable {
    case text(TerminalExternalTextInput)
    case namedKey(String)
    case key(TerminalExternalKeyEvent)
}

/// A renderer and PTY resize in both logical and backing-pixel coordinates.
public struct TerminalExternalViewport: Equatable, Sendable {
    public let widthPoints: Double
    public let heightPoints: Double
    public let widthPixels: Int
    public let heightPixels: Int
    public let xScale: Double
    public let yScale: Double
    public let proposedColumns: Int?
    public let proposedRows: Int?

    public init(
        widthPoints: Double,
        heightPoints: Double,
        widthPixels: Int,
        heightPixels: Int,
        xScale: Double,
        yScale: Double,
        proposedColumns: Int?,
        proposedRows: Int?
    ) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.xScale = xScale
        self.yScale = yScale
        self.proposedColumns = proposedColumns
        self.proposedRows = proposedRows
    }
}

/// Pointer action encoded by the daemon against canonical terminal mouse modes.
public enum TerminalExternalMouseAction: Equatable, Sendable {
    case press
    case release
    case motion
}

/// Physical pointer or wheel button.
public enum TerminalExternalMouseButton: Equatable, Sendable {
    case left
    case right
    case middle
    case wheelUp
    case wheelDown
    case wheelLeft
    case wheelRight
}

/// Normalized pointer input in terminal surface pixels.
public struct TerminalExternalMouseEvent: Equatable, Sendable {
    public let action: TerminalExternalMouseAction
    public let button: TerminalExternalMouseButton?
    public let modifiers: TerminalExternalKeyModifiers
    public let xPixels: Double
    public let yPixels: Double
    public let anyButtonPressed: Bool
    public let clickCount: UInt32

    public init(
        action: TerminalExternalMouseAction,
        button: TerminalExternalMouseButton?,
        modifiers: TerminalExternalKeyModifiers,
        xPixels: Double,
        yPixels: Double,
        anyButtonPressed: Bool,
        clickCount: UInt32 = 1
    ) {
        self.action = action
        self.button = button
        self.modifiers = modifiers
        self.xPixels = xPixels
        self.yPixels = yPixels
        self.anyButtonPressed = anyButtonPressed
        self.clickCount = clickCount
    }
}

/// A daemon-resolved OSC 8 target tied to the exact frame and presentation
/// used for pointer hit testing.
public struct TerminalExternalHyperlinkHit: Equatable, Sendable {
    public let target: String
    public let contentSequence: UInt64
    public let presentationGeneration: UInt64
    public let column: UInt16
    public let row: UInt64

    public init(
        target: String,
        contentSequence: UInt64,
        presentationGeneration: UInt64,
        column: UInt16,
        row: UInt64
    ) {
        self.target = target
        self.contentSequence = contentSequence
        self.presentationGeneration = presentationGeneration
        self.column = column
        self.row = row
    }
}

/// AppKit IME state. All offsets use UTF-16 code units.
public struct TerminalExternalPreedit: Equatable, Sendable {
    public let text: String
    public let selectionStartUTF16: UInt32
    public let selectionLengthUTF16: UInt32
    public let caretUTF16: UInt32

    public init(
        text: String,
        selectionStartUTF16: UInt32,
        selectionLengthUTF16: UInt32,
        caretUTF16: UInt32
    ) {
        self.text = text
        self.selectionStartUTF16 = selectionStartUTF16
        self.selectionLengthUTF16 = selectionLengthUTF16
        self.caretUTF16 = caretUTF16
    }

    public static func collapsedAtEnd(_ text: String) -> Self {
        let end = UInt32(clamping: text.utf16.count)
        return Self(
            text: text,
            selectionStartUTF16: end,
            selectionLengthUTF16: 0,
            caretUTF16: end
        )
    }
}

/// Every state-changing operation crosses one bounded ordered ingress.
/// Input and actions retain FIFO order. Consecutive presentation-state
/// mutations may converge to their newest value before the next strict action.
public enum TerminalExternalRuntimeMutation: Equatable, Sendable {
    case input(TerminalExternalInput)
    /// Visual-only IME marked text. `nil` clears it and never writes to the PTY.
    case preedit(TerminalExternalPreedit?)
    case mouse(TerminalExternalMouseEvent)
    case focus(Bool)
    case visibility(Bool)
    case resize(TerminalExternalViewport)
    case bindingAction(action: String, repeatCount: UInt32)
    case selection(TerminalExternalSelectionOperation)
    case copyMode(
        operation: TerminalExternalCopyModeOperation,
        adjustment: TerminalExternalCopyModeAdjustment?,
        count: UInt32
    )
    case search(operation: TerminalExternalSearchOperation, query: String?)
    case scroll(operation: TerminalExternalScrollOperation, amount: Int64?)
    case reparent(workspaceID: UUID)
    case closeCanonicalTerminal
}

public enum TerminalExternalSelectionOperation: Equatable, Sendable {
    case read
    case clear
    case selectAll
}

public enum TerminalExternalCopyModeOperation: Equatable, Sendable {
    case enter
    case exit
    case startSelection
    case startLineSelection
    case clearSelection
    case adjust
    case copyAndExit
}

public enum TerminalExternalCopyModeAdjustment: Equatable, Sendable {
    case left, right, up, down, home, end
    case pageUp, pageDown, beginningOfLine, endOfLine
}

public enum TerminalExternalSearchOperation: Equatable, Sendable {
    case start, update, next, previous, end
}

public enum TerminalExternalScrollOperation: Equatable, Sendable {
    case lines, pages, top, bottom
}

/// Why an operation was not admitted to the runtime's bounded queue.
public enum TerminalExternalIngressRejection: Equatable, Sendable {
    case queueFull
    case processExited
    case unavailable
    case unsupported
}

/// Synchronous admission result for the ordered, nonblocking ingress.
///
/// An accepted sequence number is assigned by the runtime before this method
/// returns. It proves ordering without claiming the backend has already
/// executed the operation.
public enum TerminalExternalIngressResult: Equatable, Sendable {
    case accepted(sequence: UInt64)
    case rejected(TerminalExternalIngressRejection)

    public var accepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// A bounded screen-text request fulfilled by the persistent runtime.
public enum TerminalExternalScreenTextRequest: Equatable, Sendable {
    case visible
    case vtTail(maxRows: Int, maxBytes: Int)
}

/// Main-actor façade for a terminal whose PTY, Ghostty state, and renderer are
/// owned outside the Swift app process.
///
/// `enqueue` must only perform bounded queue admission. It must not block on
/// IPC. Strict mutations execute in ascending sequence order; focus,
/// visibility, resize, and preedit may be superseded before the next strict
/// mutation while their final state remains ordered around that barrier.
@MainActor
public protocol TerminalExternalRuntime: AnyObject {
    var snapshot: TerminalExternalRuntimeSnapshot { get }

    func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease

    /// Adopts a daemon-committed placement without issuing a second topology
    /// mutation. Implementations must invalidate presentation state tied to the
    /// previous workspace before rendering or accepting geometry again.
    func adoptCanonicalPlacement(workspaceID: UUID)

    @discardableResult
    func enqueue(_ mutation: TerminalExternalRuntimeMutation) -> TerminalExternalIngressResult

    func readScreenText(_ request: TerminalExternalScreenTextRequest) async -> String?

    /// Reads and refreshes the backend-owned selection without blocking AppKit.
    func readSelection() async -> TerminalExternalSelection?

    /// Enables demand-driven semantic accessibility reads for this presentation.
    func enableAccessibility()

    /// Streams only snapshots whose revision tuple changed.
    func accessibilitySnapshots() -> AsyncStream<TerminalAccessibilitySnapshot>

    /// Revalidates a link against the daemon before returning its target.
    func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) async -> String?

    /// Resolves a pointer cell against the last admitted renderer frame.
    func activateHyperlink(at event: TerminalExternalMouseEvent) async
        -> TerminalExternalHyperlinkHit?
}

public extension TerminalExternalRuntime {
    func adoptCanonicalPlacement(workspaceID: UUID) {
        _ = workspaceID
    }

    func enableAccessibility() {}

    func accessibilitySnapshots() -> AsyncStream<TerminalAccessibilitySnapshot> {
        AsyncStream { $0.finish() }
    }

    func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) async -> String? {
        _ = link
        _ = snapshot
        return nil
    }

    func activateHyperlink(at event: TerminalExternalMouseEvent) async
        -> TerminalExternalHyperlinkHit? {
        _ = event
        return nil
    }
}
