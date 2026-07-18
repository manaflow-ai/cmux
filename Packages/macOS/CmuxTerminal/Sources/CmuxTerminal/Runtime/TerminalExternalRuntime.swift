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
        viewportState: TerminalExternalViewportState? = nil
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

/// Every state-changing operation crosses one FIFO ingress.
public enum TerminalExternalRuntimeMutation: Equatable, Sendable {
    case input(TerminalExternalInput)
    /// Visual-only IME marked text. `nil` clears it and never writes to the PTY.
    case preedit(String?)
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
/// IPC, and accepted calls must execute in ascending sequence order.
@MainActor
public protocol TerminalExternalRuntime: AnyObject {
    var snapshot: TerminalExternalRuntimeSnapshot { get }

    func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease

    @discardableResult
    func enqueue(_ mutation: TerminalExternalRuntimeMutation) -> TerminalExternalIngressResult

    func readScreenText(_ request: TerminalExternalScreenTextRequest) async -> String?

    /// Reads and refreshes the backend-owned selection without blocking AppKit.
    func readSelection() async -> TerminalExternalSelection?
}
