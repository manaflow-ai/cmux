import AppKit
import CmuxTerminalCore
import GhosttyKit

/// A terminal cell, counted from the top-left of the viewport.
struct TerminalAgentKeyHintCell: Equatable {
    var row: Int
    var column: Int
}

/// Per-view pointer state for clickable agent key hints (`agentActions.keyHints`).
@MainActor
final class TerminalAgentKeyHintPointerState {
    /// The cell a single left click pressed, while the setting is on.
    var pressCell: TerminalAgentKeyHintCell?
    /// The cell hover last resolved; hover resolves again only when it changes.
    var hoverCell: TerminalAgentKeyHintCell?
    /// The hint under the pointer: its row and cells.
    var hoveredHint: (row: Int, columns: Range<Int>)?
    var underlineView: GhosttyFlashOverlayView?
    var toolTipTag: NSView.ToolTipTag?
    /// Tooltip owners are not retained by AppKit.
    var toolTipText: NSString?
}

extension GhosttyNSView {
    // MARK: Click

    /// Remembers a single left press's cell so its release can tell a click
    /// from a drag. Does nothing while the setting is off.
    func noteAgentKeyHintPress(at point: NSPoint, clickCount: Int) {
        agentKeyHintPointer.pressCell = nil
        guard clickCount == 1, TerminalPanel.agentKeyHintsEnabled else { return }
        agentKeyHintPointer.pressCell = agentKeyHintCell(at: point)
    }

    /// Resolves a left release to a hint press before the release reaches
    /// Ghostty. The returned closure presses the hint; call it after the
    /// release is sent. A non-nil result means the release must not also
    /// open a link or path.
    func agentKeyHintPressForRelease(
        at point: NSPoint,
        clickCount: Int,
        pressModifierFlags: NSEvent.ModifierFlags?,
        surface: ghostty_surface_t
    ) -> (() -> Void)? {
        let pressCell = agentKeyHintPointer.pressCell
        agentKeyHintPointer.pressCell = nil
        guard let pressCell, let pressModifierFlags, clickCount == 1,
              agentKeyHintCell(at: point) == pressCell,
              !ghostty_surface_has_selection(surface),
              let panel = agentKeyHintPanel(), panel.agentKeyHintAgent != nil,
              let snapshot = visibleWordPathSnapshot(at: point, panel: panel),
              let click = panel.agentKeyHintClick(
                  line: snapshot.line,
                  column: snapshot.column,
                  mouseCaptured: ghostty_surface_mouse_captured(surface),
                  modifierFlags: pressModifierFlags
              ) else { return nil }
        return { [weak panel] in
            _ = panel?.pressAgentKeyHint(click)
        }
    }

    // MARK: Hover

    /// Underlines the hint under the pointer and shows a pointing hand and a
    /// tooltip. Resolves only when the pointer's cell changes, and does
    /// nothing while the setting is off or the pane runs no agent.
    func updateAgentKeyHintHover(at point: NSPoint) {
        guard TerminalPanel.agentKeyHintsEnabled, let cell = agentKeyHintCell(at: point) else {
            clearAgentKeyHintHover()
            return
        }
        let state = agentKeyHintPointer
        guard cell != state.hoverCell else {
            if state.hoveredHint != nil { NSCursor.pointingHand.set() }
            return
        }
        state.hoverCell = cell
        if let hovered = state.hoveredHint, hovered.row == cell.row, hovered.columns.contains(cell.column) {
            NSCursor.pointingHand.set()
            return
        }
        guard let surface = terminalSurface?.surface,
              let panel = agentKeyHintPanel(), panel.agentKeyHintAgent != nil,
              let snapshot = visibleWordPathSnapshot(at: point, panel: panel),
              let match = panel.agentKeyHint(inLine: snapshot.line, atColumn: snapshot.column) else {
            hideAgentKeyHintHover()
            return
        }
        let keys = panel.agentKeyHintKeys(for: match.hint, agent: match.agent)
        showAgentKeyHintHover(
            row: cell.row,
            columns: match.hint.columns,
            toolTip: Self.agentKeyHintToolTip(
                keys: keys,
                action: match.hint.action,
                needsCommand: ghostty_surface_mouse_captured(surface)
            )
        )
    }

    /// Hides any hint hover, for the pointer leaving the terminal.
    func clearAgentKeyHintHover() {
        agentKeyHintPointer.hoverCell = nil
        hideAgentKeyHintHover()
    }

    private func showAgentKeyHintHover(row: Int, columns: Range<Int>, toolTip: String) {
        guard let geometry = agentKeyHintGeometry() else { return }
        let state = agentKeyHintPointer
        hideAgentKeyHintHover()
        state.hoveredHint = (row, columns)
        let cellRect = NSRect(
            x: geometry.xInset + CGFloat(columns.lowerBound) * geometry.cellWidth,
            y: bounds.height - geometry.yInset - CGFloat(row + 1) * geometry.cellHeight,
            width: CGFloat(columns.count) * geometry.cellWidth,
            height: geometry.cellHeight
        )
        let underline: GhosttyFlashOverlayView
        if let existing = state.underlineView {
            underline = existing
        } else {
            underline = GhosttyFlashOverlayView(frame: .zero)
            underline.wantsLayer = true
            addSubview(underline, positioned: .above, relativeTo: nil)
            state.underlineView = underline
        }
        underline.layer?.backgroundColor = NSColor.linkColor.cgColor
        underline.frame = NSRect(x: cellRect.minX, y: cellRect.minY + 1, width: cellRect.width, height: 1)
        underline.isHidden = false
        let toolTipText = toolTip as NSString
        state.toolTipText = toolTipText
        state.toolTipTag = addToolTip(cellRect, owner: toolTipText, userData: nil)
        NSCursor.pointingHand.set()
    }

    private func hideAgentKeyHintHover() {
        let state = agentKeyHintPointer
        guard state.hoveredHint != nil else { return }
        state.hoveredHint = nil
        state.underlineView?.isHidden = true
        if let tag = state.toolTipTag {
            removeToolTip(tag)
            state.toolTipTag = nil
        }
        state.toolTipText = nil
        window?.invalidateCursorRects(for: self)
        Self.ghosttyMouseCursor(for: ghosttyMouseShape).set()
    }

    /// "Click to press ⌃O (expand)", with ⌘-click when the agent owns the mouse.
    static func agentKeyHintToolTip(keys: [String], action: String, needsCommand: Bool) -> String {
        let shortcut = keys.map(agentKeyHintDisplay).joined(separator: " ")
        if needsCommand {
            return String(
                localized: "terminal.agentKeyHint.commandClickToPress",
                defaultValue: "⌘-click to press \(shortcut) (\(action))"
            )
        }
        return String(
            localized: "terminal.agentKeyHint.clickToPress",
            defaultValue: "Click to press \(shortcut) (\(action))"
        )
    }

    /// `ctrl+shift+o` as `⌃⇧O`, `escape` as `⎋`.
    static func agentKeyHintDisplay(_ key: String) -> String {
        let parts = key.split(separator: "+").map(String.init)
        guard let base = parts.last else { return key }
        let glyphs: [String: String] = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧"]
        let modifiers = parts.dropLast().compactMap { glyphs[$0] }.joined()
        let named: [String: String] = [
            "escape": "⎋", "tab": "⇥", "enter": "↩", "space": "Space", "up": "↑", "down": "↓",
            "left": "←", "right": "→", "backspace": "⌫", "delete": "⌦", "pageup": "⇞",
            "pagedown": "⇟", "home": "↖", "end": "↘",
        ]
        return modifiers + (named[base] ?? base.uppercased())
    }

    // MARK: Geometry

    private struct AgentKeyHintGeometry {
        var rows: Int
        var columns: Int
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var xInset: CGFloat
        var yInset: CGFloat
    }

    /// The grid geometry `visibleWordPathSnapshot(at:panel:)` maps points with.
    private func agentKeyHintGeometry() -> AgentKeyHintGeometry? {
        guard let surface = terminalSurface?.surface else { return nil }
        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let columns = max(Int(size.columns), 1)
        let cellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let cellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        return AgentKeyHintGeometry(
            rows: rows,
            columns: columns,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            xInset: max(0, (bounds.width - CGFloat(columns) * cellWidth) / 2),
            yInset: max(0, (bounds.height - CGFloat(rows) * cellHeight) / 2)
        )
    }

    private func agentKeyHintCell(at point: NSPoint) -> TerminalAgentKeyHintCell? {
        guard bounds.contains(point), let geometry = agentKeyHintGeometry() else { return nil }
        let yFromTop = bounds.height - point.y
        return TerminalAgentKeyHintCell(
            row: max(0, min(geometry.rows - 1, Int((yFromTop - geometry.yInset) / geometry.cellHeight))),
            column: max(0, min(geometry.columns - 1, Int((point.x - geometry.xInset) / geometry.cellWidth)))
        )
    }

    private func agentKeyHintPanel() -> TerminalPanel? {
        guard let terminalSurface else { return nil }
        if let dock = DockSplitStore.liveStore(containingPanel: terminalSurface.id) {
            return dock.panels[terminalSurface.id] as? TerminalPanel
        }
        return terminalSurface.owningWorkspace()?.terminalPanel(for: terminalSurface.id)
    }
}
