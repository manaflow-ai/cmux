import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Keyboard copy mode
extension GhosttyNSView {
    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        guard surface != nil else { return false }
        setKeyboardCopyModeActive(!keyboardCopyModeActive)
        if !keyboardCopyModeActive, let surface {
            _ = ghostty_surface_clear_selection_compat(surface)
        }
        return true
    }

    func setKeyboardCopyModeActive(_ active: Bool) {
        keyboardCopyModeInputState.reset()
        keyboardCopyModeVisualActive = false
        keyboardCopyModePendingViewportJumpGeneration += 1
        keyboardCopyModePendingViewportJumpSync = false
        keyboardCopyModePendingViewportJumpScrollbarOffset = nil
        keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
        keyboardCopyModeActive = active
        if active, let surface {
            _ = ghostty_surface_clear_selection_compat(surface)
            keyboardCopyModeCursor = keyboardCopyModeInitialCursor(surface: surface)
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        } else {
            keyboardCopyModeCursor = nil
            syncKeyboardCopyModeCursorOverlay()
        }
        terminalSurface?.setKeyboardCopyModeActive(active)
    }

    func performBindingAction(_ action: String, repeatCount: Int) {
        let count = terminalKeyboardCopyModeClampCount(repeatCount)
        for _ in 0 ..< count {
            _ = performBindingAction(action)
        }
    }

    private func currentKeyboardCopyModeViewportRow(surface: ghostty_surface_t) -> Int {
        let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
            ?? max(Int(ghostty_surface_size(surface).rows), 1)
        let fallback = rows - 1
        return max(0, min(rows - 1, keyboardCopyModeCursor?.row ?? fallback))
    }

    private struct KeyboardCopyModeGridMetrics {
        let rows: Int
        let columns: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let xInset: CGFloat
        let yInset: CGFloat
        let viewHeight: CGFloat

        func topOriginRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
            CGRect(
                x: xInset + (CGFloat(cursor.column) * cellWidth),
                y: yInset + (CGFloat(cursor.row) * cellHeight),
                width: cellWidth,
                height: cellHeight
            )
        }

        func appKitRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
            let topOrigin = topOriginRect(for: cursor)
            let rawY = viewHeight - topOrigin.maxY
            let maxY = max(viewHeight - topOrigin.height, 0)
            return CGRect(
                x: topOrigin.minX,
                y: min(max(rawY, 0), maxY),
                width: topOrigin.width,
                height: topOrigin.height
            )
        }
    }

    private func keyboardCopyModeGridMetrics(surface: ghostty_surface_t) -> KeyboardCopyModeGridMetrics? {
        let size = ghostty_surface_size(surface)
        let backingRows = max(Int(size.rows), 1)
        let columns = max(Int(size.columns), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let rows = terminalKeyboardCopyModeVisibleViewportRows(
            backingRows: backingRows,
            viewHeight: Double(bounds.height),
            cellHeight: Double(resolvedCellHeight)
        )
        let terminalWidth = CGFloat(columns) * resolvedCellWidth
        let terminalHeight = CGFloat(rows) * resolvedCellHeight
        return KeyboardCopyModeGridMetrics(
            rows: rows,
            columns: columns,
            cellWidth: resolvedCellWidth,
            cellHeight: resolvedCellHeight,
            xInset: max(0, (bounds.width - terminalWidth) / 2),
            yInset: max(0, (bounds.height - terminalHeight) / 2),
            viewHeight: bounds.height
        )
    }

    private func keyboardCopyModeInitialCursor(surface: ghostty_surface_t) -> TerminalKeyboardCopyModeCursor {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            return TerminalKeyboardCopyModeCursor(row: 0, column: 0)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let row = terminalKeyboardCopyModeInitialViewportRow(
            rows: metrics.rows,
            imePointY: y,
            imeCellHeight: Double(metrics.cellHeight),
            topPadding: Double(metrics.yInset)
        )
        let column = terminalKeyboardCopyModeInitialViewportColumn(
            columns: metrics.columns,
            imePointX: x,
            imeCellWidth: Double(metrics.cellWidth),
            leftPadding: Double(metrics.xInset)
        )
        return TerminalKeyboardCopyModeCursor(row: row, column: column)
    }

    func syncKeyboardCopyModeCursorOverlay(surface explicitSurface: ghostty_surface_t? = nil) {
        guard keyboardCopyModeActive,
              !keyboardCopyModeVisualActive,
              let surface = explicitSurface ?? self.surface,
              let cursor = keyboardCopyModeCursor,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            keyboardCopyModeCursorOverlayView.isHidden = true
            return
        }

        let clampedCursor = cursor.clamped(rows: metrics.rows, columns: metrics.columns)
        if clampedCursor != cursor {
            keyboardCopyModeCursor = clampedCursor
        }

        keyboardCopyModeCursorOverlayView.frame = metrics.appKitRect(for: clampedCursor)
        keyboardCopyModeCursorOverlayView.isHidden = false
    }

    private func moveKeyboardCopyModeCursor(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        let scrollDelta = cursor.move(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        keyboardCopyModeCursor = cursor
        if scrollDelta != 0 {
            _ = performBindingAction("scroll_page_lines:\(scrollDelta)")
        }
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func clampKeyboardCopyModeCursor(surface: ghostty_surface_t) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: Int? = nil) {
        keyboardCopyModePendingViewportJumpGeneration += 1
        keyboardCopyModePendingViewportJumpSync = true
        keyboardCopyModePendingViewportJumpScrollbarOffset = scrollbar?.offset
        keyboardCopyModePendingViewportJumpFallbackLineDelta = fallbackLineDelta
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    }

    private func scheduleKeyboardCopyModeViewportJumpCursorSyncFallback() {
        let generation = keyboardCopyModePendingViewportJumpGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.previewKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.expireKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: generation)
        }
    }

    private func previewKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard keyboardCopyModePendingViewportJumpSync,
              generation == keyboardCopyModePendingViewportJumpGeneration,
              keyboardCopyModeActive,
              let surface else { return }

        if flushPendingScrollbarIfAvailable() {
            return
        }

        if let lineDelta = keyboardCopyModePendingViewportJumpFallbackLineDelta,
           lineDelta != 0,
           keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta == 0 {
            shiftKeyboardCopyModeCursorForViewportScroll(lineDelta: lineDelta, surface: surface)
            keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = lineDelta
            return
        }

        clampKeyboardCopyModeCursor(surface: surface)
    }

    private func expireKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard keyboardCopyModePendingViewportJumpSync,
              generation == keyboardCopyModePendingViewportJumpGeneration else { return }

        keyboardCopyModePendingViewportJumpSync = false
        keyboardCopyModePendingViewportJumpScrollbarOffset = nil
        keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    }

    func finishKeyboardCopyModeViewportJumpCursorSyncIfNeeded(newScrollbar: GhosttyScrollbar? = nil) {
        guard keyboardCopyModePendingViewportJumpSync else { return }
        keyboardCopyModePendingViewportJumpSync = false
        defer {
            keyboardCopyModePendingViewportJumpScrollbarOffset = nil
            keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
            keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
        }

        guard keyboardCopyModeActive, let surface else { return }
        let resolvedNewOffset = newScrollbar?.offset ?? scrollbar?.offset
        if let previousOffset = keyboardCopyModePendingViewportJumpScrollbarOffset,
           let resolvedNewOffset {
            let lineDelta = keyboardCopyModeViewportLineDelta(
                from: previousOffset,
                to: resolvedNewOffset
            )
            let remainingLineDelta = lineDelta - keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta
            if remainingLineDelta != 0 {
                shiftKeyboardCopyModeCursorForViewportScroll(lineDelta: remainingLineDelta, surface: surface)
                return
            }
        }

        clampKeyboardCopyModeCursor(surface: surface)
    }

    private func keyboardCopyModeViewportLineDelta(from previousOffset: UInt64, to currentOffset: UInt64) -> Int {
        if currentOffset >= previousOffset {
            return Int(clamping: currentOffset - previousOffset)
        }
        return -Int(clamping: previousOffset - currentOffset)
    }

    private func updateKeyboardCopyModeCursorModel(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        cursor.moveAfterTerminalSelectionAdjustment(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        keyboardCopyModeCursor = cursor
    }

    private func shiftKeyboardCopyModeCursorForViewportScroll(
        lineDelta: Int,
        surface: ghostty_surface_t
    ) {
        guard lineDelta != 0,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        cursor.shiftForViewportScroll(lineDelta: lineDelta, rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func adjustKeyboardCopyModeSelection(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        let action = "adjust_selection:\(direction.rawValue)"
        let clampedCount = terminalKeyboardCopyModeClampCount(count)
        for _ in 0 ..< clampedCount {
            _ = performBindingAction(action)
            updateKeyboardCopyModeCursorModel(direction, count: 1, surface: surface)
        }
    }

    private func selectKeyboardCopyModeCursorCell(surface: ghostty_surface_t) -> Bool {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }

        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor

        let rect = metrics.topOriginRect(for: cursor)
        let y = min(max(rect.midY, 0), max(bounds.height - 1, 0))
        guard let xRange = terminalKeyboardCopyModeCursorSelectionXRange(
            rectMinX: Double(rect.minX),
            rectMaxX: Double(rect.maxX),
            boundsWidth: Double(bounds.width)
        ) else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        let mods = GHOSTTY_MODS_NONE

        _ = ghostty_surface_clear_selection_compat(surface)
        ghostty_surface_mouse_pos(surface, xRange.startX, Double(y), mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        ghostty_surface_mouse_pos(surface, xRange.endX, Double(y), mods)
        let selectedCursorCell = ghostty_surface_has_selection(surface)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        guard selectedCursorCell else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        return true
    }

    private func copyCurrentViewportLinesToClipboard(
        surface: ghostty_surface_t,
        startRow: Int,
        lineCount: Int
    ) -> Bool {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }
        let clampedCount = terminalKeyboardCopyModeClampCount(lineCount)
        let rows = metrics.rows
        let targetRow = max(0, min(rows - 1, startRow))
        let endRow = min(rows - 1, targetRow + clampedCount - 1)
        _ = ghostty_surface_clear_selection_compat(surface)

        let yMax = max(bounds.height - 1, 0)

        let startRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: targetRow, column: 0)
        ).midY
        let endRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: endRow, column: max(metrics.columns - 1, 0))
        ).midY
        let startY = max(0, min(startRawY, yMax))
        let endY = max(0, min(endRawY, yMax))
        let xMax = max(bounds.width - 1, 0)
        let startX = min(metrics.xInset + 0.5, xMax)
        let endX = min(metrics.xInset + (CGFloat(metrics.columns) * metrics.cellWidth) - 0.5, xMax)

        let mods = GHOSTTY_MODS_NONE
        ghostty_surface_mouse_pos(surface, Double(startX), Double(startY), mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            return false
        }
        defer {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }
        ghostty_surface_mouse_pos(surface, Double(endX), Double(endY), mods)
        guard ghostty_surface_has_selection(surface) else { return false }

        return performBindingAction("copy_to_clipboard")
    }

    func handleKeyboardCopyModeIfNeeded(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        guard keyboardCopyModeActive else { return false }

        if terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: event.modifierFlags) {
            keyboardCopyModeInputState.reset()
            return false
        }

        // Use the visual-mode flag instead of raw has_selection; non-visual
        // cursor state is owned by the copy-mode cursor model.
        let hasSelection = keyboardCopyModeVisualActive
        let resolution = terminalKeyboardCopyModeResolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            hasSelection: hasSelection,
            state: &keyboardCopyModeInputState
        )
        guard case let .perform(action, count) = resolution else {
            return true
        }

        switch action {
        case .exit:
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case .startSelection:
            if selectKeyboardCopyModeCursorCell(surface: surface) {
                keyboardCopyModeVisualActive = true
                syncKeyboardCopyModeCursorOverlay(surface: surface)
            }
        case .clearSelection:
            keyboardCopyModeVisualActive = false
            _ = ghostty_surface_clear_selection_compat(surface)
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case .copyAndExit:
            _ = performBindingAction("copy_to_clipboard")
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case .copyLineAndExit:
            let startRow = currentKeyboardCopyModeViewportRow(surface: surface)
            _ = copyCurrentViewportLinesToClipboard(
                surface: surface,
                startRow: startRow,
                lineCount: count
            )
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case let .scrollLines(delta):
            let lineDelta = delta * terminalKeyboardCopyModeClampCount(count)
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: lineDelta)
            _ = performBindingAction("scroll_page_lines:\(lineDelta)")
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .scrollPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
                ?? max(Int(ghostty_surface_size(surface).rows), 1)
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: delta * rows * clampedCount)
            performBindingAction(delta > 0 ? "scroll_page_down" : "scroll_page_up", repeatCount: clampedCount)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .scrollHalfPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let fraction = delta > 0 ? 0.5 : -0.5
            let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
                ?? max(Int(ghostty_surface_size(surface).rows), 1)
            let linesPerScroll = Int((Double(rows) * 0.5).rounded(.towardZero))
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: delta * linesPerScroll * clampedCount)
            performBindingAction("scroll_page_fractional:\(fraction)", repeatCount: clampedCount)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .scrollToTop:
            if var cursor = keyboardCopyModeCursor {
                if let metrics = keyboardCopyModeGridMetrics(surface: surface) {
                    _ = cursor.move(.home, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    cursor.row = 0
                    cursor.column = 0
                }
                keyboardCopyModeCursor = cursor
            }
            _ = performBindingAction("scroll_to_top")
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case .scrollToBottom:
            if var cursor = keyboardCopyModeCursor {
                if let metrics = keyboardCopyModeGridMetrics(surface: surface) {
                    _ = cursor.move(.end, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    let size = ghostty_surface_size(surface)
                    cursor.row = max(Int(size.rows) - 1, 0)
                    cursor.column = max(Int(size.columns) - 1, 0)
                }
                keyboardCopyModeCursor = cursor
            }
            _ = performBindingAction("scroll_to_bottom")
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case let .jumpToPrompt(delta):
            beginKeyboardCopyModeViewportJumpCursorSync()
            _ = performBindingAction("jump_to_prompt:\(delta * count)")
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .startSearch:
            _ = performBindingAction("start_search")
        case .searchNext:
            beginKeyboardCopyModeViewportJumpCursorSync()
            performBindingAction("navigate_search:next", repeatCount: count)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .searchPrevious:
            beginKeyboardCopyModeViewportJumpCursorSync()
            performBindingAction("navigate_search:previous", repeatCount: count)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .adjustSelection(direction):
            if keyboardCopyModeVisualActive {
                adjustKeyboardCopyModeSelection(direction, count: count, surface: surface)
            } else {
                moveKeyboardCopyModeCursor(direction, count: count, surface: surface)
            }
        }
        return true
    }

    // MARK: - Input Handling

}
