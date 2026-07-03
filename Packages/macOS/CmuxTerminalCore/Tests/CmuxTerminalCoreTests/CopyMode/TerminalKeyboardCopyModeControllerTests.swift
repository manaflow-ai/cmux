import CoreGraphics
import GhosttyKit
import Testing
@testable import CmuxTerminalCore

@MainActor
private final class FakeCopyModeHost: TerminalSurfaceGridReading {
    var metrics: TerminalKeyboardCopyModeGridMetrics?
    var imePoint: TerminalSurfaceIMEPoint? = TerminalSurfaceIMEPoint(x: 0, y: 0)
    var scrollbarOffset: UInt64?
    var scrollbarTotal: UInt64?
    var scrollbarVisibleLength: UInt64?
    var hasSurface = true
    var selectCellResult = true
    var selectViewportLinesResult = true
    var copyCurrentSelectionResult = true
    var copyVisualLineSelectionResult = true
    var copyLinesResult = true
    var runtimeSelectionActive = false

    var bindingActions: [String] = []
    var clearSelectionCount = 0
    var overlayRects: [CGRect?] = []
    var activeChanges: [Bool] = []
    var scheduledGenerations: [Int] = []
    var selectedViewportLines: [(startRow: Int, lineCount: Int)] = []
    var copiedVisualLineSelections: [TerminalKeyboardCopyModeVisualLineSelection] = []
    var flushReturns = false

    func copyModeHasSurface() -> Bool { hasSurface }
    func copyModeGridMetrics() -> TerminalKeyboardCopyModeGridMetrics? { metrics }
    func copyModeViewportRowCount() -> Int { metrics?.rows ?? 24 }
    func copyModeViewportColumnCount() -> Int { metrics?.columns ?? 80 }
    func copyModeIMEPoint() -> TerminalSurfaceIMEPoint? { imePoint }
    func copyModeScrollbarOffset() -> UInt64? { scrollbarOffset }
    func copyModeScrollbarTotal() -> UInt64? { scrollbarTotal }
    func copyModeScrollbarVisibleLength() -> UInt64? { scrollbarVisibleLength }

    @discardableResult
    func copyModePerformBindingAction(_ action: String) -> Bool {
        bindingActions.append(action)
        return true
    }

    func copyModeClearSelection() { clearSelectionCount += 1 }
    func copyModeHasRuntimeSelection() -> Bool { runtimeSelectionActive }

    func copyModeSelectCursorCell(
        metrics: TerminalKeyboardCopyModeGridMetrics,
        cursor: TerminalKeyboardCopyModeCursor
    ) -> Bool { selectCellResult }

    func copyModeSelectViewportLines(
        metrics: TerminalKeyboardCopyModeGridMetrics,
        startRow: Int,
        lineCount: Int
    ) -> Bool {
        selectedViewportLines.append((startRow: startRow, lineCount: lineCount))
        return selectViewportLinesResult
    }

    func copyModeCopyCurrentSelectionToClipboard() -> Bool {
        bindingActions.append("copy_to_clipboard")
        return copyCurrentSelectionResult
    }

    func copyModeCopyVisualLineSelection(
        _ selection: TerminalKeyboardCopyModeVisualLineSelection,
        metrics: TerminalKeyboardCopyModeGridMetrics,
        maxBytes: UInt
    ) -> Bool {
        copiedVisualLineSelections.append(selection)
        return copyVisualLineSelectionResult
    }

    func copyModeCopyViewportLines(
        metrics: TerminalKeyboardCopyModeGridMetrics,
        startRow: Int,
        lineCount: Int
    ) -> Bool { copyLinesResult }

    func copyModeApplyCursorOverlay(rect: CGRect?) { overlayRects.append(rect) }

    @discardableResult
    func copyModeFlushPendingScrollbarIfAvailable() -> Bool { flushReturns }

    func copyModeScheduleViewportJumpFallback(generation: Int) {
        scheduledGenerations.append(generation)
    }

    func copyModeActiveDidChange(_ active: Bool) { activeChanges.append(active) }
}

@MainActor
@Suite("Terminal keyboard copy mode controller")
struct TerminalKeyboardCopyModeControllerTests {
    private func makeController(
        rows: Int = 24,
        columns: Int = 80
    ) -> (TerminalKeyboardCopyModeController, FakeCopyModeHost) {
        let host = FakeCopyModeHost()
        host.metrics = TerminalKeyboardCopyModeGridMetrics(
            rows: rows,
            columns: columns,
            cellWidth: 8,
            cellHeight: 16,
            xInset: 0,
            yInset: 0,
            viewHeight: CGFloat(rows) * 16
        )
        let controller = TerminalKeyboardCopyModeController()
        controller.host = host
        return (controller, host)
    }

    @Test func toggleActivatesAndDeactivates() {
        let (controller, host) = makeController()
        #expect(controller.isActive == false)

        #expect(controller.toggle())
        #expect(controller.isActive)
        #expect(host.activeChanges == [true])

        #expect(controller.toggle())
        #expect(controller.isActive == false)
        // Leaving clears the selection (setActive(false) does not clear; toggle does).
        #expect(host.clearSelectionCount >= 1)
        #expect(host.activeChanges == [true, false])
    }

    @Test func toggleRefusesWithoutSurface() {
        let (controller, host) = makeController()
        host.hasSurface = false
        #expect(controller.toggle() == false)
        #expect(controller.isActive == false)
    }

    @Test func exitKeyLeavesCopyMode() {
        let (controller, host) = makeController()
        _ = host
        controller.setActive(true)
        // Escape (keyCode 53) exits.
        let handled = controller.handleKeyIfNeeded(
            keyCode: 53,
            charactersIgnoringModifiers: nil,
            modifiers: []
        )
        #expect(handled)
        #expect(controller.isActive == false)
    }

    @Test func commandModifierBypassesCopyMode() {
        let (controller, _) = makeController()
        controller.setActive(true)
        let handled = controller.handleKeyIfNeeded(
            keyCode: 8,
            charactersIgnoringModifiers: "c",
            modifiers: [.command]
        )
        #expect(handled == false)
    }

    @Test func startSelectionThenCopyAndExit() {
        let (controller, host) = makeController()
        controller.setActive(true)
        host.bindingActions.removeAll()

        // v -> start visual selection
        _ = controller.handleKeyIfNeeded(keyCode: 9, charactersIgnoringModifiers: "v", modifiers: [])
        // y -> copy and exit (hasSelection true)
        _ = controller.handleKeyIfNeeded(keyCode: 16, charactersIgnoringModifiers: "y", modifiers: [])

        #expect(host.bindingActions.contains("copy_to_clipboard"))
        #expect(controller.isActive == false)
    }

    @Test func startLineSelectionThenCopyAndExitCopiesAbsoluteRows() {
        let (controller, host) = makeController()
        host.scrollbarOffset = 100
        host.scrollbarTotal = 200
        host.scrollbarVisibleLength = 24
        controller.setActive(true)
        host.selectedViewportLines.removeAll()

        _ = controller.handleKeyIfNeeded(keyCode: 9, charactersIgnoringModifiers: "v", modifiers: [.shift])
        #expect(controller.hasCopyableSelection())
        #expect(host.selectedViewportLines.last?.startRow == 0)
        #expect(host.selectedViewportLines.last?.lineCount == 1)

        _ = controller.handleKeyIfNeeded(keyCode: 16, charactersIgnoringModifiers: "y", modifiers: [])

        #expect(host.copiedVisualLineSelections == [
            TerminalKeyboardCopyModeVisualLineSelection(anchorScreenRow: 100, endpointScreenRow: 100),
        ])
        #expect(controller.isActive == false)
    }

    @Test func visualLineMotionExtendsRuntimeSelection() {
        let (controller, host) = makeController()
        host.scrollbarOffset = 100
        host.scrollbarTotal = 200
        host.scrollbarVisibleLength = 24
        controller.setActive(true)
        host.selectedViewportLines.removeAll()

        _ = controller.handleKeyIfNeeded(keyCode: 9, charactersIgnoringModifiers: "v", modifiers: [.shift])
        _ = controller.handleKeyIfNeeded(keyCode: 38, charactersIgnoringModifiers: "j", modifiers: [])

        #expect(host.selectedViewportLines.last?.startRow == 0)
        #expect(host.selectedViewportLines.last?.lineCount == 2)
    }

    @Test func clearSelectionClearsVisualLineSelection() {
        let (controller, host) = makeController()
        host.scrollbarOffset = 100
        host.scrollbarTotal = 200
        host.scrollbarVisibleLength = 24
        controller.setActive(true)

        _ = controller.handleKeyIfNeeded(keyCode: 9, charactersIgnoringModifiers: "v", modifiers: [.shift])
        _ = controller.handleKeyIfNeeded(keyCode: 9, charactersIgnoringModifiers: "v", modifiers: [])

        #expect(controller.hasCopyableSelection() == false)
        #expect(host.clearSelectionCount >= 1)
    }

    @Test func downMotionMovesCursorWithoutLeavingMode() {
        let (controller, host) = makeController()
        controller.setActive(true)
        host.bindingActions.removeAll()

        let handled = controller.handleKeyIfNeeded(
            keyCode: 38,
            charactersIgnoringModifiers: "j",
            modifiers: []
        )
        #expect(handled)
        #expect(controller.isActive)
    }

    @Test func consumedKeyUpRoundTrips() {
        let (controller, _) = makeController()
        controller.recordConsumedKeyUp(42)
        #expect(controller.consumeKeyUpIfNeeded(42))
        #expect(controller.consumeKeyUpIfNeeded(42) == false)
    }

    @Test func keyTableIndicatorReflectsActiveTable() {
        let (controller, host) = makeController()
        _ = host
        #expect(controller.keyStateIndicator == nil)
        controller.setActive(true)
        #expect(controller.keyStateIndicator == .copyMode)
        controller.setActive(false)

        controller.activateKeyTable(name: "vim")
        #expect(controller.keyStateIndicator == .copyMode)
        #expect(controller.hasPendingKeySequenceOrKeyTable)
        controller.deactivateAllKeyTables()
        #expect(controller.hasPendingKeySequenceOrKeyTable == false)
    }

    @Test func scrollPageBeginsViewportJumpAndSchedulesFallback() {
        let (controller, host) = makeController()
        controller.setActive(true)
        host.bindingActions.removeAll()
        host.scheduledGenerations.removeAll()

        // Ctrl-f -> scroll page forward (no selection).
        _ = controller.handleKeyIfNeeded(
            keyCode: 3,
            charactersIgnoringModifiers: "f",
            modifiers: [.control]
        )
        #expect(host.bindingActions.contains("scroll_page_down"))
        #expect(host.scheduledGenerations.isEmpty == false)
    }
}
