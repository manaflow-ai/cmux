import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

/// A terminal cell, counted from the top-left of the viewport.
struct TerminalAgentKeyHintCell: Equatable {
    var row: Int
    var column: Int
}

/// What the viewport showed when a hover resolved: a hint underline stays
/// only while scrolling, new output that moves the cursor, and resizes leave
/// this unchanged.
struct TerminalAgentKeyHintViewportState: Equatable {
    var scrollbarTotal: UInt64
    var scrollbarOffset: UInt64
    var scrollbarLength: UInt64
    var rows: Int
    var columns: Int
    var cursorRow: Int?
    var cursorColumn: Int?

    /// The rows where the agent's live UI is, for bare key hints.
    var liveRegion: AgentKeyHintLiveRegion {
        AgentKeyHintLiveRegion(
            viewportAtBottom: scrollbarOffset + scrollbarLength >= scrollbarTotal,
            cursorRow: cursorRow
        )
    }
}

/// Per-view pointer state for clickable agent key hints (`agentActions.keyHints`).
@MainActor
final class TerminalAgentKeyHintPointerState {
    /// The cell a single left click pressed, while the setting is on.
    var pressCell: TerminalAgentKeyHintCell?
    /// A released click waiting out the double-click interval.
    var deferredPress = AgentKeyHintDeferredPress(delay: NSEvent.doubleClickInterval)
    var pendingPress: (() -> Void)?
    /// The cell hover last resolved; hover resolves again only when it changes.
    var hoverCell: TerminalAgentKeyHintCell?
    /// The hint under the pointer: its row and cells.
    var hoveredHint: (row: Int, columns: Range<Int>)?
    /// The viewport the hovered hint was read from.
    var hoveredViewport: TerminalAgentKeyHintViewportState?
    var underlineView: GhosttyFlashOverlayView?
    var toolTipTag: NSView.ToolTipTag?
    /// Tooltip owners are not retained by AppKit.
    var toolTipText: NSString?
}

extension GhosttyNSView {
    /// How long hover trusts an earlier check of `~/.claude/keybindings.json`.
    private static let agentKeyHintHoverKeybindingsMaxAge: TimeInterval = 5

    // MARK: Click

    /// Settles a click still waiting to press a hint, for any left press:
    /// the second press of a double click cancels it, a new single click
    /// presses it now. Runs before anything else in `mouseDown`.
    func settleAgentKeyHintPendingPress(clickCount: Int) {
        let state = agentKeyHintPointer
        guard state.pendingPress != nil else { return }
        let due = state.deferredPress.press(clickCount: clickCount)
        let press = state.pendingPress
        state.pendingPress = nil
        if due { press?() }
    }

    /// Remembers a single left press's cell so its release can tell a click
    /// from a drag. Does nothing while the setting is off.
    func noteAgentKeyHintPress(at point: NSPoint, clickCount: Int) {
        agentKeyHintPointer.pressCell = nil
        guard clickCount == 1, TerminalPanel.agentKeyHintsEnabled else { return }
        agentKeyHintPointer.pressCell = agentKeyHintCell(at: point)
    }

    /// Resolves a left release to a hint press before the release reaches
    /// Ghostty. A non-nil result means the release must not also open a
    /// link or path; call it after the release is sent. It presses the hint
    /// once the double-click interval passes without a second press, so the
    /// first click of a double or triple click presses nothing.
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
              let panel = agentKeyHintPanel(),
              let row = agentKeyHintRow(pressCell.row, surface: surface),
              let click = panel.agentKeyHintClick(
                  line: row.line,
                  column: pressCell.column,
                  inLiveRegion: row.viewport.liveRegion.contains(row: pressCell.row),
                  mouseCaptured: ghostty_surface_mouse_captured(surface),
                  modifierFlags: pressModifierFlags
              ) else { return nil }
        return { [weak self, weak panel] in
            guard let self else { return }
            let state = self.agentKeyHintPointer
            state.pendingPress = { [weak panel] in _ = panel?.pressAgentKeyHint(click) }
            let due = state.deferredPress.release(at: ProcessInfo.processInfo.systemUptime)
            // A little past the deadline, so the timer never finds it not yet due.
            let delay = max(0, due - ProcessInfo.processInfo.systemUptime) + 0.01
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let state = self.agentKeyHintPointer
                guard state.deferredPress.fire(at: ProcessInfo.processInfo.systemUptime) else { return }
                let press = state.pendingPress
                state.pendingPress = nil
                press?()
            }
        }
    }

    // MARK: Hover

    /// Underlines the hint under the pointer and shows a pointing hand and a
    /// tooltip. Reads one terminal row, and only when the pointer's cell
    /// changes or the viewport under a shown hint changed. Does nothing while
    /// the setting is off or the pane runs no agent.
    func updateAgentKeyHintHover(at point: NSPoint) {
        guard TerminalPanel.agentKeyHintsEnabled, let cell = agentKeyHintCell(at: point) else {
            clearAgentKeyHintHover()
            return
        }
        let state = agentKeyHintPointer
        if let hovered = state.hoveredHint, hovered.row == cell.row, hovered.columns.contains(cell.column) {
            // Still over the shown hint: keep it while the viewport is unchanged.
            if let surface = terminalSurface?.surface, agentKeyHintViewportState(surface) == state.hoveredViewport {
                state.hoverCell = cell
                NSCursor.pointingHand.set()
                return
            }
        } else if cell == state.hoverCell {
            return
        }
        state.hoverCell = cell
        guard let surface = terminalSurface?.surface,
              let panel = agentKeyHintPanel(), let agent = panel.agentKeyHintAgent,
              let row = agentKeyHintRow(cell.row, surface: surface),
              let hint = TerminalPanel.agentKeyHint(
                  inLine: row.line,
                  atColumn: cell.column,
                  agent: agent,
                  isLiveRow: { row.viewport.liveRegion.contains(row: cell.row) }
              ) else {
            hideAgentKeyHintHover()
            return
        }
        let keys = panel.agentKeyHintKeys(
            for: hint,
            agent: agent,
            keybindingsMaxAge: Self.agentKeyHintHoverKeybindingsMaxAge
        )
        showAgentKeyHintHover(
            row: cell.row,
            columns: hint.columns,
            viewport: row.viewport,
            toolTip: Self.agentKeyHintToolTip(
                keys: keys,
                action: hint.action,
                needsCommand: ghostty_surface_mouse_captured(surface),
                physicalKeys: AgentKeyHintPhysicalKeyboardStore.shared.advice(forAgentKeys: keys)
            )
        )
    }

    /// Hides any hint hover, for the pointer leaving the terminal, a scroll,
    /// or a resize. The next mouse move resolves hover again.
    func clearAgentKeyHintHover() {
        let state = agentKeyHintPointer
        state.hoverCell = nil
        hideAgentKeyHintHover()
    }

    private func showAgentKeyHintHover(
        row: Int,
        columns: Range<Int>,
        viewport: TerminalAgentKeyHintViewportState,
        toolTip: String
    ) {
        guard let geometry = agentKeyHintGeometry() else { return }
        let state = agentKeyHintPointer
        hideAgentKeyHintHover()
        state.hoveredHint = (row, columns)
        state.hoveredViewport = viewport
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
        state.hoveredViewport = nil
        state.underlineView?.isHidden = true
        if let tag = state.toolTipTag {
            removeToolTip(tag)
            state.toolTipTag = nil
        }
        state.toolTipText = nil
        window?.invalidateCursorRects(for: self)
        Self.ghosttyMouseCursor(for: ghosttyMouseShape).set()
    }

    /// "Click to press ⌃O (expand)", with ⌘-click when the agent owns the
    /// mouse, then a line for each group of keyboards where other physical
    /// keys produce the chord: "On your keyboard: ⇪O (Caps Lock is your
    /// Control key)".
    static func agentKeyHintToolTip(
        keys: [String],
        action: String,
        needsCommand: Bool,
        physicalKeys: [PhysicalKeyAdvice] = []
    ) -> String {
        let shortcut = keys.map(agentKeyHintDisplay).joined(separator: " ")
        let press: String
        if needsCommand {
            press = String(
                localized: "terminal.agentKeyHint.commandClickToPress",
                defaultValue: "⌘-click to press \(shortcut) (\(action))"
            )
        } else {
            press = String(
                localized: "terminal.agentKeyHint.clickToPress",
                defaultValue: "Click to press \(shortcut) (\(action))"
            )
        }
        return ([press] + physicalKeys.map(agentKeyHintPhysicalKeysLine)).joined(separator: "\n")
    }

    /// "On your keyboard: ⇪O (Caps Lock is your Control key)", or "On
    /// <keyboard name>: ..." when other keyboards press the printed keys.
    static func agentKeyHintPhysicalKeysLine(_ advice: PhysicalKeyAdvice) -> String {
        let keys = advice.chords.map(\.glyphs).joined(separator: " ")
        var reasons = advice.notes.map { note in
            let physical = agentKeyHintKeyName(note.physical)
            let sends = agentKeyHintKeyName(note.sends)
            return String(
                localized: "terminal.agentKeyHint.physicalKeys.keyIsYourKey",
                defaultValue: "\(physical) is your \(sends) key"
            )
        }
        var rightHand: [PhysicalKey] = []
        for key in advice.chords.flatMap(\.rightHandModifiers) where !rightHand.contains(key) {
            rightHand.append(key)
        }
        for key in rightHand {
            let name = agentKeyHintKeyName(key)
            reasons.append(String(
                localized: "terminal.agentKeyHint.physicalKeys.rightHandKey",
                defaultValue: "use the right \(name) key"
            ))
        }
        if advice.viaKarabinerRule {
            reasons.append(String(
                localized: "terminal.agentKeyHint.physicalKeys.karabinerRule",
                defaultValue: "a Karabiner-Elements rule sends it"
            ))
        }
        let reason = reasons.joined(separator: ", ")
        let names = advice.keyboardNames.filter { !$0.isEmpty }
        if advice.appliesToEveryKeyboard || names.isEmpty {
            if reason.isEmpty {
                return String(
                    localized: "terminal.agentKeyHint.physicalKeys.yourKeyboard",
                    defaultValue: "On your keyboard: \(keys)"
                )
            }
            return String(
                localized: "terminal.agentKeyHint.physicalKeys.yourKeyboardWithReason",
                defaultValue: "On your keyboard: \(keys) (\(reason))"
            )
        }
        let keyboards = names.joined(separator: ", ")
        if reason.isEmpty {
            return String(
                localized: "terminal.agentKeyHint.physicalKeys.namedKeyboard",
                defaultValue: "On \(keyboards): \(keys)"
            )
        }
        return String(
            localized: "terminal.agentKeyHint.physicalKeys.namedKeyboardWithReason",
            defaultValue: "On \(keyboards): \(keys) (\(reason))"
        )
    }

    /// A key's localized name ("Caps Lock", "Control"), or its glyph for
    /// keys that read fine as one.
    static func agentKeyHintKeyName(_ key: PhysicalKey) -> String {
        switch key.name {
        case .control?:
            String(localized: "terminal.agentKeyHint.keyName.control", defaultValue: "Control")
        case .option?:
            String(localized: "terminal.agentKeyHint.keyName.option", defaultValue: "Option")
        case .shift?:
            String(localized: "terminal.agentKeyHint.keyName.shift", defaultValue: "Shift")
        case .command?:
            String(localized: "terminal.agentKeyHint.keyName.command", defaultValue: "Command")
        case .capsLock?:
            String(localized: "terminal.agentKeyHint.keyName.capsLock", defaultValue: "Caps Lock")
        case .escape?:
            String(localized: "terminal.agentKeyHint.keyName.escape", defaultValue: "Escape")
        case nil:
            key.glyph
        }
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

    /// The grid geometry that maps points to cells, as the Command-click
    /// path fallback maps them.
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

    /// Viewport row `row` as its own cells (no joining of soft-wrapped
    /// lines, no trimming of blank rows), with the viewport it was read from.
    private func agentKeyHintRow(
        _ row: Int,
        surface: ghostty_surface_t
    ) -> (line: String, viewport: TerminalAgentKeyHintViewportState)? {
        guard let terminalSurface, let viewport = agentKeyHintViewportState(surface),
              row >= 0, row < viewport.rows,
              let line = terminalSurface.readText(region: .viewportRow(row, columns: viewport.columns))
        else { return nil }
        return (line, viewport)
    }

    private func agentKeyHintViewportState(_ surface: ghostty_surface_t) -> TerminalAgentKeyHintViewportState? {
        var scrollbar = ghostty_surface_scrollbar_s()
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_scrollbar(surface, &scrollbar),
              ghostty_surface_grid_metrics(surface, &metrics),
              metrics.rows > 0, metrics.columns > 0 else { return nil }
        return TerminalAgentKeyHintViewportState(
            scrollbarTotal: scrollbar.total,
            scrollbarOffset: scrollbar.offset,
            scrollbarLength: scrollbar.len,
            rows: Int(metrics.rows),
            columns: Int(metrics.columns),
            cursorRow: metrics.cursor_in_viewport ? Int(metrics.cursor_row) : nil,
            cursorColumn: metrics.cursor_in_viewport ? Int(metrics.cursor_column) : nil
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
