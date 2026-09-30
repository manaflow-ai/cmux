import AppKit
import CmuxSettings
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
        state.cancelDeferredPressTask()
        let due = state.deferredPress.press(clickCount: clickCount)
        let press = state.pendingPress
        state.pendingPress = nil
        if due { press?() }
    }

    /// Fires a released click once its double-click deadline passes. The timer
    /// and deterministic regression coverage share this consumption path.
    func fireAgentKeyHintPendingPress(at now: TimeInterval) {
        let state = agentKeyHintPointer
        state.cancelDeferredPressTask()
        guard state.deferredPress.fire(at: now) else { return }
        let press = state.pendingPress
        state.pendingPress = nil
        press?()
    }

    /// Drops both halves of an in-progress hint click. Explicit lifecycle and
    /// input invalidations, such as detach and scroll, call this immediately.
    func cancelAgentKeyHintInteraction() {
        let state = agentKeyHintPointer
        state.cancelDeferredPressTask()
        state.pressCell = nil
        state.deferredPress.cancel()
        state.pendingPress = nil
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
              let terminalSurface,
              terminalSurface.surface == surface else { return nil }
        let runtimeSurfaceGeneration = terminalSurface.runtimeSurfaceGeneration
        guard let panel = agentKeyHintPanel(),
              let row = agentKeyHintRow(pressCell.row, surface: surface),
              let click = panel.agentKeyHintClick(
                  line: row.line,
                  column: pressCell.column,
                  inLiveRegion: row.viewport.liveRegion.contains(row: pressCell.row),
                  mouseCaptured: ghostty_surface_mouse_captured(surface),
                  modifierFlags: pressModifierFlags
              ),
              terminalSurface.surface == surface,
              terminalSurface.runtimeSurfaceGeneration == runtimeSurfaceGeneration else { return nil }
        let request = TerminalAgentKeyHintDeferredRequest(
            terminalSurfaceIdentity: ObjectIdentifier(terminalSurface),
            runtimeSurfaceGeneration: runtimeSurfaceGeneration,
            panelIdentity: ObjectIdentifier(panel),
            cell: pressCell,
            row: row.line,
            viewport: row.viewport,
            click: click,
            modifierFlags: pressModifierFlags
        )
        return { [weak self] in
            self?.deferAgentKeyHintPress(request)
        }
    }

    /// Installs the real deferred callback. The injectable reads make the
    /// callback's stale-row and stale-runtime rejection directly testable
    /// without passing synthetic pointers through Ghostty's C API.
    func deferAgentKeyHintPress(
        _ request: TerminalAgentKeyHintDeferredRequest,
        currentSnapshot: @escaping () -> TerminalAgentKeyHintDeferredSnapshot?,
        press: @escaping (TerminalPanel, TerminalPanel.AgentKeyHintClick) -> Void
    ) {
        let state = agentKeyHintPointer
        state.cancelDeferredPressTask()
        state.pendingPress = {
            guard let snapshot = currentSnapshot(),
                  ObjectIdentifier(snapshot.terminalSurface) == request.terminalSurfaceIdentity,
                  snapshot.runtimeSurfaceGeneration == request.runtimeSurfaceGeneration,
                  ObjectIdentifier(snapshot.panel) == request.panelIdentity,
                  snapshot.cell == request.cell,
                  snapshot.row == request.row,
                  snapshot.viewport == request.viewport,
                  !snapshot.hasSelection,
                  let currentClick = snapshot.panel.revalidatedAgentKeyHintClick(
                      request.click,
                      line: snapshot.row,
                      column: snapshot.cell.column,
                      inLiveRegion: snapshot.viewport.liveRegion.contains(row: snapshot.cell.row),
                      mouseCaptured: snapshot.mouseCaptured,
                      modifierFlags: request.modifierFlags
                  )
            else { return }
            press(snapshot.panel, currentClick)
        }
        let due = state.deferredPress.release(at: ProcessInfo.processInfo.systemUptime)
        // A little past the deadline, so the task never finds it not yet due.
        let delay = max(0, due - ProcessInfo.processInfo.systemUptime) + 0.01
        let sequence = state.deferredPressTaskSequence
        let sleep = state.deferredPressSleep
        state.deferredPressTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            let currentState = self.agentKeyHintPointer
            guard currentState.deferredPressTaskSequence == sequence else { return }
            currentState.deferredPressTask = nil
            self.fireAgentKeyHintPendingPress(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func deferAgentKeyHintPress(_ request: TerminalAgentKeyHintDeferredRequest) {
        deferAgentKeyHintPress(
            request,
            currentSnapshot: { [weak self] in
                self?.agentKeyHintDeferredSnapshot(at: request.cell)
            },
            press: { panel, click in
                _ = panel.pressAgentKeyHint(click)
            }
        )
    }

    private func agentKeyHintDeferredSnapshot(
        at cell: TerminalAgentKeyHintCell
    ) -> TerminalAgentKeyHintDeferredSnapshot? {
        guard let terminalSurface else { return nil }
        let runtimeSurfaceGeneration = terminalSurface.runtimeSurfaceGeneration
        guard let surface = terminalSurface.surface,
              let panel = agentKeyHintPanel(),
              let row = agentKeyHintRow(cell.row, surface: surface),
              terminalSurface.surface == surface,
              terminalSurface.runtimeSurfaceGeneration == runtimeSurfaceGeneration else { return nil }
        return TerminalAgentKeyHintDeferredSnapshot(
            terminalSurface: terminalSurface,
            runtimeSurfaceGeneration: runtimeSurfaceGeneration,
            panel: panel,
            cell: cell,
            row: row.line,
            viewport: row.viewport,
            hasSelection: ghostty_surface_has_selection(surface),
            mouseCaptured: ghostty_surface_mouse_captured(surface)
        )
    }

    // MARK: Hover

    /// Underlines the hint under the pointer and shows a pointing hand and a
    /// tooltip. Reads one terminal row, and only when the pointer's cell
    /// changes or the viewport under a shown hint changed. Does nothing while
    /// the setting is off or the pane runs no agent.
    func updateAgentKeyHintHover(at point: NSPoint) {
        updateAgentKeyHintRestMarkers()
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
              let row = agentKeyHintRow(cell.row, surface: surface) else {
            hideAgentKeyHintHover()
            return
        }
        let live = row.viewport.liveRegion.contains(row: cell.row)
        if let hint = TerminalPanel.agentKeyHint(
            inLine: row.line,
            atColumn: cell.column,
            agent: agent,
            isLiveRow: { live }
        ) {
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
                    needsCommand: ghostty_surface_mouse_captured(surface)
                )
            )
            return
        }
        guard agent == .codex, live,
              let command = CodexActionCommandDetector().command(in: row.line, atColumn: cell.column) else {
            hideAgentKeyHintHover()
            return
        }
        showAgentKeyHintHover(
            row: cell.row,
            columns: command.columns,
            viewport: row.viewport,
            toolTip: Self.agentActionCommandToolTip(
                command: command.command,
                needsCommand: ghostty_surface_mouse_captured(surface)
            )
        )
    }

    /// Paints calm markers for clickable spans in the live region. The
    /// viewport and row hash gate keeps this off the typing path and avoids
    /// rebuilding overlays when Ghostty re-renders identical content.
    func updateAgentKeyHintRestMarkers() {
        let state = agentKeyHintPointer
        let style = AgentActionsCatalogSection().keyHintRestStyle.value(in: .standard)
        guard TerminalPanel.agentKeyHintsEnabled,
              style != .none,
              isVisibleInUI,
              let surface = terminalSurface?.surface,
              let panel = agentKeyHintPanel(),
              let agent = panel.agentKeyHintAgent,
              let viewport = agentKeyHintViewportState(surface),
              let firstRow = viewport.liveRegion.firstRow else {
            hideAgentKeyHintRestMarkers()
            return
        }
        let lastRow = min(viewport.rows - 1, viewport.cursorRow! + 1)
        let rows = (firstRow...lastRow).compactMap { row -> (row: Int, text: String)? in
            guard let text = terminalSurface?.readText(region: .viewportRow(row, columns: viewport.columns)) else { return nil }
            return (row, text)
        }
        var hash: UInt64 = 1469598103934665603
        for row in rows {
            hash ^= UInt64(row.row)
            hash &*= 1099511628211
            for byte in row.text.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
        }
        guard state.restViewport != viewport || state.restRowsHash != hash else { return }
        state.restViewport = viewport
        state.restRowsHash = hash
        let spanStyle: AgentKeyHintRestSpanStyle = style == .dotted ? .dotted : .underline
        let spans = agentKeyHintRestSpans(
            rows: rows,
            agent: agent,
            viewportAtBottom: viewport.liveRegion.firstRow != nil,
            cursorRow: viewport.cursorRow,
            style: spanStyle
        )
        guard let geometry = agentKeyHintGeometry() else { return }
        for (index, span) in spans.enumerated() {
            let view: GhosttyFlashOverlayView
            if index < state.restMarkerViews.count {
                view = state.restMarkerViews[index]
            } else {
                view = GhosttyFlashOverlayView(frame: .zero)
                view.wantsLayer = true
                addSubview(view, positioned: .above, relativeTo: nil)
                state.restMarkerViews.append(view)
            }
            let x = geometry.xInset + CGFloat(span.columns.lowerBound) * geometry.cellWidth
            let y = bounds.height - geometry.yInset - CGFloat(span.row + 1) * geometry.cellHeight + 1
            view.frame = NSRect(x: x, y: y, width: CGFloat(span.columns.count) * geometry.cellWidth, height: 2)
            configureAgentKeyHintRestMarker(view, style: span.style)
            view.isHidden = false
        }
        for view in state.restMarkerViews.dropFirst(spans.count) { view.isHidden = true }
    }

    private func configureAgentKeyHintRestMarker(
        _ view: GhosttyFlashOverlayView,
        style: AgentKeyHintRestSpanStyle
    ) {
        let tint = NSColor.linkColor.withAlphaComponent(style == .dotted ? 0.22 : 0.42)
        guard style == .dotted else {
            view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            view.layer?.backgroundColor = tint.cgColor
            return
        }
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let line: CAShapeLayer
        if let existing = view.layer?.sublayers?.first as? CAShapeLayer {
            line = existing
        } else {
            line = CAShapeLayer()
            view.layer?.addSublayer(line)
        }
        line.frame = view.bounds
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0.5))
        path.addLine(to: CGPoint(x: view.bounds.width, y: 0.5))
        line.path = path
        line.strokeColor = tint.cgColor
        line.fillColor = NSColor.clear.cgColor
        line.lineWidth = 1
        line.lineDashPattern = [1, 2]
    }

    private func hideAgentKeyHintRestMarkers() {
        let state = agentKeyHintPointer
        state.restViewport = nil
        state.restRowsHash = nil
        for view in state.restMarkerViews { view.isHidden = true }
    }

    /// Hides any hint hover and cancels an unreleased press. A completed click
    /// keeps waiting through pointer exit and no-op layout. Scroll and detach
    /// cancel it; final snapshot validation rejects real viewport changes.
    func clearAgentKeyHintHover() {
        let state = agentKeyHintPointer
        state.pressCell = nil
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

    static func agentActionCommandToolTip(command: String, needsCommand: Bool) -> String {
        if needsCommand {
            return "⌘-click to run \(command)"
        }
        return "Click to run \(command)"
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
