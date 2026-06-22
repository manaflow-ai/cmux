public import CoreGraphics
public import GhosttyKit
public import Observation

/// Owns the terminal keyboard copy-mode (vim-mode) state machine.
///
/// `TerminalKeyboardCopyModeController` is the relocated home of the copy-mode
/// subsystem that previously lived inline in the AppKit `GhosttyNSView`. It owns
/// every piece of copy-mode state, the active flag, the cursor model, the pending
/// viewport-jump tracking, the multi-key input state, and the Ghostty key-sequence
/// and key-table stacks, and runs the full per-key state machine.
///
/// The controller performs no Ghostty C calls and holds no AppKit views. It reads
/// the live grid and drives all side effects through a
/// ``TerminalSurfaceGridReading`` host (the live `GhosttyNSView`), which keeps the
/// latency-sensitive `ghostty_surface_t` reads and NSView coordinate conversion
/// app-side. The visible cursor overlay tracks ``cursorOverlayRect`` (the host's
/// overlay view binds to it via ``TerminalSurfaceGridReading/copyModeApplyCursorOverlay(rect:)``).
///
/// ```swift
/// let controller = TerminalKeyboardCopyModeController()
/// controller.host = liveSurfaceView
/// controller.toggle()
/// ```
@MainActor
@Observable
public final class TerminalKeyboardCopyModeController {
    /// The host that feeds live grid geometry and performs Ghostty side effects.
    ///
    /// Held weakly because the host (the live surface view) owns the controller.
    @ObservationIgnored
    public weak var host: (any TerminalSurfaceGridReading)?

    /// Whether keyboard copy mode is currently active.
    public private(set) var isActive = false

    /// The AppKit-coordinate rect for the cursor overlay, or `nil` when hidden.
    ///
    /// The host's overlay view binds to this value; it is updated as the single
    /// writer whenever the cursor or grid changes.
    public private(set) var cursorOverlayRect: CGRect?

    /// The localized-independent key-state indicator classification, or `nil`.
    ///
    /// Resolves to the active key-table indicator when one is pushed, otherwise the
    /// copy-mode indicator when copy mode is active.
    public var keyStateIndicator: TerminalKeyTableIndicator? {
        if let name = keyTables.last {
            return TerminalKeyTableIndicator(name: name)
        }
        if isActive {
            return TerminalKeyTableIndicator.copyMode
        }
        return nil
    }

    // MARK: Copy-mode state

    private var inputState = TerminalKeyboardCopyModeInputState()
    private var cursor: TerminalKeyboardCopyModeCursor?
    /// Tracks whether the user has explicitly entered visual selection mode (v).
    /// Separate from Ghostty's `has_selection` because non-visual copy mode keeps
    /// the cursor in overlay state until visual selection starts.
    private var visualActive = false
    private var consumedKeyUps: Set<UInt16> = []

    private var pendingViewportJumpSync = false
    private var pendingViewportJumpScrollbarOffset: UInt64?
    private var pendingViewportJumpGeneration = 0
    private var pendingViewportJumpFallbackLineDelta: Int?
    private var pendingViewportJumpAppliedFallbackLineDelta = 0

    // MARK: Ghostty key-sequence / key-table stacks

    private var keySequence: [ghostty_input_trigger_s] = []
    private var keyTables: [String] = []

    /// Whether there is a pending Ghostty key sequence or active key table.
    ///
    /// Callers use this to decide whether to retry the main menu for a consumed
    /// binding (a partial sequence or active table means the event is in-flight).
    public var hasPendingKeySequenceOrKeyTable: Bool {
        !keySequence.isEmpty || !keyTables.isEmpty
    }

    /// Creates an inactive copy-mode controller.
    public init() {}

    // MARK: Active-state control

    /// Toggles keyboard copy mode, clearing the selection when leaving.
    ///
    /// - Returns: `true` when the toggle was applied; `false` when there is no surface.
    @discardableResult
    public func toggle() -> Bool {
        guard let host, host.copyModeHasSurface() else {
            // Mirrors the legacy `guard surface != nil` precondition.
            return false
        }
        setActive(!isActive)
        if !isActive {
            host.copyModeClearSelection()
        }
        return true
    }

    /// Sets copy-mode active state, resetting all transient state and the cursor.
    ///
    /// - Parameter active: The desired active state.
    public func setActive(_ active: Bool) {
        guard let host else { return }
        inputState.reset()
        visualActive = false
        pendingViewportJumpGeneration += 1
        pendingViewportJumpSync = false
        pendingViewportJumpScrollbarOffset = nil
        pendingViewportJumpFallbackLineDelta = nil
        pendingViewportJumpAppliedFallbackLineDelta = 0
        isActive = active
        if active {
            host.copyModeClearSelection()
            cursor = initialCursor()
            syncCursorOverlay()
        } else {
            cursor = nil
            syncCursorOverlay()
        }
        host.copyModeActiveDidChange(active)
    }

    // MARK: Grid reads

    /// The viewport row currently occupied by the cursor.
    ///
    /// - Returns: A zero-based viewport row clamped into the grid.
    public func currentViewportRow() -> Int {
        guard let host else { return 0 }
        let rows = host.copyModeGridMetrics()?.rows ?? max(host.copyModeViewportRowCount(), 1)
        let fallback = rows - 1
        return max(0, min(rows - 1, cursor?.row ?? fallback))
    }

    private func initialCursor() -> TerminalKeyboardCopyModeCursor {
        guard let host, let metrics = host.copyModeGridMetrics() else {
            return TerminalKeyboardCopyModeCursor(row: 0, column: 0)
        }
        guard let point = host.copyModeIMEPoint() else {
            return TerminalKeyboardCopyModeCursor(row: 0, column: 0)
        }
        let row = terminalKeyboardCopyModeInitialViewportRow(
            rows: metrics.rows,
            imePointY: point.y,
            imeCellHeight: Double(metrics.cellHeight),
            topPadding: Double(metrics.yInset)
        )
        let column = terminalKeyboardCopyModeInitialViewportColumn(
            columns: metrics.columns,
            imePointX: point.x,
            imeCellWidth: Double(metrics.cellWidth),
            leftPadding: Double(metrics.xInset)
        )
        return TerminalKeyboardCopyModeCursor(row: row, column: column)
    }

    /// Re-syncs the cursor overlay rect against the current grid.
    ///
    /// Call this when the host relays out so the overlay stays aligned.
    public func syncCursorOverlay() {
        guard let host,
              isActive,
              !visualActive,
              let cursor,
              let metrics = host.copyModeGridMetrics() else {
            cursorOverlayRect = nil
            host?.copyModeApplyCursorOverlay(rect: nil)
            return
        }
        let clampedCursor = cursor.clamped(rows: metrics.rows, columns: metrics.columns)
        if clampedCursor != cursor {
            self.cursor = clampedCursor
        }
        let rect = metrics.appKitRect(for: clampedCursor)
        cursorOverlayRect = rect
        host.copyModeApplyCursorOverlay(rect: rect)
    }

    private func moveCursor(_ direction: TerminalKeyboardCopyModeSelectionMove, count: Int) {
        guard let host, let metrics = host.copyModeGridMetrics() else { return }
        var cursor = self.cursor ?? initialCursor()
        let scrollDelta = cursor.move(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        self.cursor = cursor
        if scrollDelta != 0 {
            host.copyModePerformBindingAction("scroll_page_lines:\(scrollDelta)")
        }
        syncCursorOverlay()
    }

    private func clampCursor() {
        guard let host, let metrics = host.copyModeGridMetrics() else { return }
        let cursor = (self.cursor ?? initialCursor())
            .clamped(rows: metrics.rows, columns: metrics.columns)
        self.cursor = cursor
        syncCursorOverlay()
    }

    // MARK: Viewport-jump cursor sync

    private func beginViewportJumpCursorSync(fallbackLineDelta: Int? = nil) {
        pendingViewportJumpGeneration += 1
        pendingViewportJumpSync = true
        pendingViewportJumpScrollbarOffset = host?.copyModeScrollbarOffset()
        pendingViewportJumpFallbackLineDelta = fallbackLineDelta
        pendingViewportJumpAppliedFallbackLineDelta = 0
    }

    private func scheduleViewportJumpCursorSyncFallback() {
        host?.copyModeScheduleViewportJumpFallback(generation: pendingViewportJumpGeneration)
    }

    /// The deferred-preview step of the viewport-jump cursor sync.
    ///
    /// - Parameter generation: The generation captured when the jump was scheduled.
    public func previewViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard let host,
              pendingViewportJumpSync,
              generation == pendingViewportJumpGeneration,
              isActive else { return }

        if host.copyModeFlushPendingScrollbarIfAvailable() {
            return
        }

        if let lineDelta = pendingViewportJumpFallbackLineDelta,
           lineDelta != 0,
           pendingViewportJumpAppliedFallbackLineDelta == 0 {
            shiftCursorForViewportScroll(lineDelta: lineDelta)
            pendingViewportJumpAppliedFallbackLineDelta = lineDelta
            return
        }

        clampCursor()
    }

    /// The deferred-expiry step of the viewport-jump cursor sync.
    ///
    /// - Parameter generation: The generation captured when the jump was scheduled.
    public func expireViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard pendingViewportJumpSync,
              generation == pendingViewportJumpGeneration else { return }

        pendingViewportJumpSync = false
        pendingViewportJumpScrollbarOffset = nil
        pendingViewportJumpFallbackLineDelta = nil
        pendingViewportJumpAppliedFallbackLineDelta = 0
    }

    /// Finishes the viewport-jump cursor sync when a fresh scrollbar lands.
    ///
    /// - Parameter newScrollbarOffset: The offset of the newly applied scrollbar, or `nil`.
    public func finishViewportJumpCursorSyncIfNeeded(newScrollbarOffset: UInt64?) {
        guard pendingViewportJumpSync else { return }
        pendingViewportJumpSync = false
        defer {
            pendingViewportJumpScrollbarOffset = nil
            pendingViewportJumpFallbackLineDelta = nil
            pendingViewportJumpAppliedFallbackLineDelta = 0
        }

        guard let host, isActive else { return }
        let resolvedNewOffset = newScrollbarOffset ?? host.copyModeScrollbarOffset()
        if let previousOffset = pendingViewportJumpScrollbarOffset,
           let resolvedNewOffset {
            let lineDelta = viewportLineDelta(from: previousOffset, to: resolvedNewOffset)
            let remainingLineDelta = lineDelta - pendingViewportJumpAppliedFallbackLineDelta
            if remainingLineDelta != 0 {
                shiftCursorForViewportScroll(lineDelta: remainingLineDelta)
                return
            }
        }

        clampCursor()
    }

    private func viewportLineDelta(from previousOffset: UInt64, to currentOffset: UInt64) -> Int {
        if currentOffset >= previousOffset {
            return Int(clamping: currentOffset - previousOffset)
        }
        return -Int(clamping: previousOffset - currentOffset)
    }

    private func updateCursorModel(_ direction: TerminalKeyboardCopyModeSelectionMove, count: Int) {
        guard let host, let metrics = host.copyModeGridMetrics() else { return }
        var cursor = self.cursor ?? initialCursor()
        cursor.moveAfterTerminalSelectionAdjustment(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        self.cursor = cursor
    }

    private func shiftCursorForViewportScroll(lineDelta: Int) {
        guard lineDelta != 0,
              let host,
              let metrics = host.copyModeGridMetrics() else { return }
        var cursor = self.cursor ?? initialCursor()
        cursor.shiftForViewportScroll(lineDelta: lineDelta, rows: metrics.rows, columns: metrics.columns)
        self.cursor = cursor
        syncCursorOverlay()
    }

    private func adjustSelection(_ direction: TerminalKeyboardCopyModeSelectionMove, count: Int) {
        guard let host else { return }
        let action = "adjust_selection:\(direction.rawValue)"
        let clampedCount = terminalKeyboardCopyModeClampCount(count)
        for _ in 0 ..< clampedCount {
            host.copyModePerformBindingAction(action)
            updateCursorModel(direction, count: 1)
        }
    }

    private func selectCursorCell() -> Bool {
        guard let host, let metrics = host.copyModeGridMetrics() else { return false }
        let cursor = (self.cursor ?? initialCursor())
            .clamped(rows: metrics.rows, columns: metrics.columns)
        self.cursor = cursor
        return host.copyModeSelectCursorCell(metrics: metrics, cursor: cursor)
    }

    private func copyCurrentViewportLinesToClipboard(startRow: Int, lineCount: Int) -> Bool {
        guard let host, host.copyModeGridMetrics() != nil else { return false }
        let metrics = host.copyModeGridMetrics()!
        return host.copyModeCopyViewportLines(
            metrics: metrics,
            startRow: startRow,
            lineCount: lineCount
        )
    }

    // MARK: Per-key state machine

    /// Records that a key-down was consumed by copy mode so its key-up is dropped.
    ///
    /// - Parameter keyCode: The hardware key code that was consumed.
    public func recordConsumedKeyUp(_ keyCode: UInt16) {
        consumedKeyUps.insert(keyCode)
    }

    /// Removes and reports whether a key-up was previously consumed by copy mode.
    ///
    /// - Parameter keyCode: The hardware key code for the key-up.
    /// - Returns: `true` when the key-up should be dropped.
    public func consumeKeyUpIfNeeded(_ keyCode: UInt16) -> Bool {
        consumedKeyUps.remove(keyCode) != nil
    }

    /// Runs the copy-mode state machine for a single decoded key event.
    ///
    /// The host decodes the `NSEvent` into the package value types and passes them
    /// in. When copy mode consumes the event, the host should record the key-up via
    /// ``recordConsumedKeyUp(_:)``.
    ///
    /// - Parameters:
    ///   - keyCode: The hardware key code for the event.
    ///   - charactersIgnoringModifiers: The layout character reported without modifiers.
    ///   - modifiers: The event modifiers as package value types.
    ///   - asciiCharacterProvider: A fallback physical-key lookup for non-ASCII input.
    /// - Returns: `true` when copy mode handled (consumed) the event.
    public func handleKeyIfNeeded(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: TerminalKeyboardCopyModeModifiers,
        asciiCharacterProvider: (UInt16) -> String? = { _ in nil }
    ) -> Bool {
        guard isActive, let host else { return false }

        if TerminalKeyboardCopyModeResolution.shouldBypassForShortcut(modifiers: modifiers) {
            inputState.reset()
            return false
        }

        // Use the visual-mode flag instead of raw has_selection; non-visual cursor
        // state is owned by the copy-mode cursor model.
        let hasSelection = visualActive
        let resolution = TerminalKeyboardCopyModeResolution.resolve(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers,
            hasSelection: hasSelection,
            state: &inputState,
            asciiCharacterProvider: asciiCharacterProvider
        )
        guard case let .perform(action, count) = resolution else {
            return true
        }

        switch action {
        case .exit:
            host.copyModeClearSelection()
            setActive(false)
        case .startSelection:
            if selectCursorCell() {
                visualActive = true
                syncCursorOverlay()
            }
        case .clearSelection:
            visualActive = false
            host.copyModeClearSelection()
            syncCursorOverlay()
        case .copyAndExit:
            host.copyModePerformBindingAction("copy_to_clipboard")
            host.copyModeClearSelection()
            setActive(false)
        case .copyLineAndExit:
            let startRow = currentViewportRow()
            _ = copyCurrentViewportLinesToClipboard(startRow: startRow, lineCount: count)
            host.copyModeClearSelection()
            setActive(false)
        case let .scrollLines(delta):
            let lineDelta = delta * terminalKeyboardCopyModeClampCount(count)
            beginViewportJumpCursorSync(fallbackLineDelta: lineDelta)
            host.copyModePerformBindingAction("scroll_page_lines:\(lineDelta)")
            scheduleViewportJumpCursorSyncFallback()
        case let .scrollPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let rows = host.copyModeGridMetrics()?.rows ?? max(host.copyModeViewportRowCount(), 1)
            beginViewportJumpCursorSync(fallbackLineDelta: delta * rows * clampedCount)
            performBindingAction(delta > 0 ? "scroll_page_down" : "scroll_page_up", repeatCount: clampedCount)
            scheduleViewportJumpCursorSyncFallback()
        case let .scrollHalfPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let fraction = delta > 0 ? 0.5 : -0.5
            let rows = host.copyModeGridMetrics()?.rows ?? max(host.copyModeViewportRowCount(), 1)
            let linesPerScroll = Int((Double(rows) * 0.5).rounded(.towardZero))
            beginViewportJumpCursorSync(fallbackLineDelta: delta * linesPerScroll * clampedCount)
            performBindingAction("scroll_page_fractional:\(fraction)", repeatCount: clampedCount)
            scheduleViewportJumpCursorSyncFallback()
        case .scrollToTop:
            if var cursor = self.cursor {
                if let metrics = host.copyModeGridMetrics() {
                    _ = cursor.move(.home, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    cursor.row = 0
                    cursor.column = 0
                }
                self.cursor = cursor
            }
            host.copyModePerformBindingAction("scroll_to_top")
            syncCursorOverlay()
        case .scrollToBottom:
            if var cursor = self.cursor {
                if let metrics = host.copyModeGridMetrics() {
                    _ = cursor.move(.end, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    cursor.row = max(host.copyModeViewportRowCount() - 1, 0)
                    cursor.column = max(host.copyModeViewportColumnCount() - 1, 0)
                }
                self.cursor = cursor
            }
            host.copyModePerformBindingAction("scroll_to_bottom")
            syncCursorOverlay()
        case let .jumpToPrompt(delta):
            beginViewportJumpCursorSync()
            host.copyModePerformBindingAction("jump_to_prompt:\(delta * count)")
            scheduleViewportJumpCursorSyncFallback()
        case .startSearch:
            host.copyModePerformBindingAction("start_search")
        case .searchNext:
            beginViewportJumpCursorSync()
            performBindingAction("navigate_search:next", repeatCount: count)
            scheduleViewportJumpCursorSyncFallback()
        case .searchPrevious:
            beginViewportJumpCursorSync()
            performBindingAction("navigate_search:previous", repeatCount: count)
            scheduleViewportJumpCursorSyncFallback()
        case let .adjustSelection(direction):
            if visualActive {
                adjustSelection(direction, count: count)
            } else {
                moveCursor(direction, count: count)
            }
        }
        return true
    }

    private func performBindingAction(_ action: String, repeatCount: Int) {
        guard let host else { return }
        let count = terminalKeyboardCopyModeClampCount(repeatCount)
        for _ in 0 ..< count {
            host.copyModePerformBindingAction(action)
        }
    }

    // MARK: Ghostty key-sequence / key-table stacks

    /// Pushes or clears the pending Ghostty key-sequence trigger stack.
    ///
    /// - Parameters:
    ///   - active: Whether the sequence is now active.
    ///   - trigger: The trigger to append when active.
    public func updateKeySequence(active: Bool, trigger: ghostty_input_trigger_s) {
        if active {
            keySequence.append(trigger)
        } else {
            keySequence.removeAll()
        }
    }

    /// Activates a named Ghostty key table.
    ///
    /// - Parameter name: The key-table name.
    public func activateKeyTable(name: String) {
        keyTables.append(name)
    }

    /// Deactivates the most recently activated Ghostty key table.
    public func deactivateKeyTable() {
        _ = keyTables.popLast()
    }

    /// Deactivates all Ghostty key tables.
    public func deactivateAllKeyTables() {
        keyTables.removeAll()
    }
}
