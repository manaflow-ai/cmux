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


// MARK: - Word-under-cursor path resolution and command-click
extension GhosttyNSView {
    enum WordPathResolutionSource: String {
        case quicklook
        case snapshot
    }

    struct WordPathResolution {
        let path: String
        let source: WordPathResolutionSource
        let rawToken: String
    }

    private func makeWordPathResolution(
        path: String,
        source: WordPathResolutionSource,
        rawToken: String
    ) -> WordPathResolution {
        WordPathResolution(
            path: path,
            source: source,
            rawToken: rawToken
        )
    }

    func shouldSuppressCommandPathHover(for flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    /// Attempt to open the word under the mouse cursor as a file path, resolved
    /// against the terminal panel's current working directory.
    private func tryOpenWordAsPath(at point: NSPoint? = nil) {
        guard let resolution = resolveWordUnderCursorPath(at: point) else { return }

        #if DEBUG
        cmuxDebugLog("link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue)")
        #endif

        PreferredEditorSettings.open(URL(fileURLWithPath: resolution.path))
    }

    /// Check if the word under the mouse cursor resolves to an existing file/directory
    /// in the terminal panel's CWD. Returns the resolved absolute path, or nil.
    private func resolveWordUnderCursorAsPath(at point: NSPoint? = nil) -> String? {
        resolveWordUnderCursorPath(at: point)?.path
    }

    func resolveWordUnderCursorPath(at point: NSPoint? = nil) -> WordPathResolution? {
        guard let surface = surface else { return nil }

        guard let termSurface = terminalSurface,
              let workspace = termSurface.owningWorkspace(),
              !workspace.isRemoteTerminalSurface(termSurface.id) else { return nil }

        guard let cwd = resolvedWordPathWorkingDirectory(workspace: workspace, terminalSurface: termSurface) else {
            return nil
        }

        let snapshotPoint = preferredPointerPoint(from: point)
        let pointSnapshotResolution = snapshotPoint.flatMap {
            resolveVisibleWordPath(
                at: $0,
                cwd: cwd,
                workspace: workspace,
                terminalSurface: termSurface
            )
        }

        var text = ghostty_text_s()
        if ghostty_surface_quicklook_word(surface, &text) {
            defer { ghostty_surface_free_text(surface, &text) }
            var quicklookResolution: WordPathResolution?
            if text.text_len > 0, let ptr = text.text {
                let wordData = Data(bytes: ptr, count: Int(text.text_len))
                if let decodedWord = String(bytes: wordData, encoding: .utf8) {
#if DEBUG
                    let resolvedQuicklookWord = cmuxTerminalCmdClickQuicklookOverride(decodedWord)
#else
                    let resolvedQuicklookWord = decodedWord
#endif
                    if let resolvedPath = cmuxResolveQuicklookPath(resolvedQuicklookWord, cwd: cwd) {
                        quicklookResolution = makeWordPathResolution(
                            path: resolvedPath,
                            source: .quicklook,
                            rawToken: resolvedQuicklookWord
                        )
                    }
                }
            }

            var viewportResolution: WordPathResolution?
            if text.offset_len > 0 {
#if DEBUG
                let viewportOffsetStart = cmuxTerminalCmdClickViewportOffsetDelta(Int(text.offset_start))
#else
                let viewportOffsetStart = Int(text.offset_start)
#endif
                viewportResolution = resolveVisibleWordPathFromViewportOffset(
                    viewportOffsetStart,
                    cwd: cwd,
                    workspace: workspace,
                    terminalSurface: termSurface
                )
            }

            if let viewportResolution {
                // The pointer-anchored snapshot is the only source tied directly to the
                // actual click location. Prefer it over quicklook and viewport offsets,
                // which can lag or target a sibling entry in multi-column `ls` output.
                if let pointSnapshotResolution {
                    return pointSnapshotResolution
                }
                return viewportResolution
            }

            if let pointSnapshotResolution {
                return pointSnapshotResolution
            }

            if let quicklookResolution {
                return quicklookResolution
            }
        }

        return pointSnapshotResolution
    }

    #if DEBUG
    private func cmuxTerminalCmdClickQuicklookOverride(_ decodedWord: String) -> String {
        let env = ProcessInfo.processInfo.environment
        guard let override = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_QUICKLOOK_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return decodedWord
        }
        return override
    }

    private func cmuxTerminalCmdClickViewportOffsetDelta(_ viewportOffsetStart: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let delta = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_VIEWPORT_OFFSET_DELTA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let parsedDelta = Int(delta) else {
            return viewportOffsetStart
        }
        return max(0, viewportOffsetStart + parsedDelta)
    }
    #endif

    /// Update the pointing-hand cursor when Cmd-hovering over a bare filename
    /// that exists in the terminal's CWD.
    func updateWordPathHover(
        at point: NSPoint? = nil,
        cmdHeld: Bool,
        suppressPathHover: Bool = false
    ) {
        let hoverWasActive = wordPathHoverActive
        guard cmdHeld, !suppressPathHover else {
            if wordPathHoverActive {
                wordPathHoverActive = false
                NSCursor.pop()
            }
#if DEBUG
            if cmdHeld || suppressPathHover || hoverWasActive {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "hover_update",
                    expected: "cmd-hover off while selection is active",
                    actual: suppressPathHover ? "suppressed" : "inactive",
                    data: [
                        "cmd_held": cmdHeld,
                        "suppress_path_hover": suppressPathHover,
                        "hover_active_before": hoverWasActive,
                        "hover_active_after": wordPathHoverActive
                    ]
                )
            }
#endif
            return
        }

        let resolution = resolveWordUnderCursorPath(at: point)
        if resolution != nil {
            if !wordPathHoverActive {
                wordPathHoverActive = true
                NSCursor.pointingHand.push()
            }
        } else if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        if cmdHeld || hoverWasActive || wordPathHoverActive || resolution != nil {
            var payload: [String: Any] = [
                "cmd_held": cmdHeld,
                "suppress_path_hover": suppressPathHover,
                "hover_active_before": hoverWasActive,
                "hover_active_after": wordPathHoverActive
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: resolution == nil ? "h1" : "h2",
                name: "hover_update",
                expected: "resolved path only when hover should activate",
                actual: wordPathHoverActive ? "hover_active" : "hover_inactive",
                data: payload
            )
        }
#endif
    }

    private func resolvedWordPathWorkingDirectory(
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> String? {
        CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: workspace,
            surfaceId: terminalSurface.id
        )
    }

    private func pointIsUsableForWordResolution(_ point: NSPoint) -> Bool {
        bounds.width > 0 &&
        bounds.height > 0 &&
        point.x >= 0 &&
        point.y >= 0 &&
        point.x <= bounds.width &&
        point.y <= bounds.height
    }

    func trackMousePointIfUsable(_ point: NSPoint) {
        guard pointIsUsableForWordResolution(point) else { return }
        lastKnownMousePointInView = point
    }

    func preferredPointerPoint(from eventPoint: NSPoint? = nil) -> NSPoint? {
        if let eventPoint, pointIsUsableForWordResolution(eventPoint) {
            lastKnownMousePointInView = eventPoint
            return eventPoint
        }
        if let currentPoint = currentMousePointInView(), pointIsUsableForWordResolution(currentPoint) {
            lastKnownMousePointInView = currentPoint
            return currentPoint
        }
        return lastKnownMousePointInView ?? eventPoint
    }

    private func currentMousePointInView() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func resolveVisibleWordPathFromViewportOffset(
        _ viewportOffsetStart: Int,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = cmuxVisibleTerminalLines(from: visibleText, rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let rowFromTop = max(0, min(rows - 1, viewportOffsetStart / cols))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, viewportOffsetStart % cols))
        guard let resolution = cmuxResolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    private func resolveVisibleWordPath(
        at point: NSPoint,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = cmuxVisibleTerminalLines(from: visibleText, rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let xInset = max(0, (bounds.width - (CGFloat(cols) * resolvedCellWidth)) / 2)
        let yInset = max(0, (bounds.height - (CGFloat(rows) * resolvedCellHeight)) / 2)

        let yFromTop = bounds.height - point.y
        let rowFromTop = max(0, min(rows - 1, Int((yFromTop - yInset) / resolvedCellHeight)))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, Int((point.x - xInset) / resolvedCellWidth)))
        guard let resolution = cmuxResolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    @discardableResult
    func handleCommandClickRelease(
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        ghosttyConsumed: Bool
    ) -> WordPathResolution? {
        guard let surface else { return nil }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: modifierFlags)
        let cmdHeld = modifierFlags.contains(.command)
        let resolvedPoint = preferredPointerPoint(from: point)
        guard cmdHeld, !suppressCommandPathHover else {
#if DEBUG
            if cmdHeld || suppressCommandPathHover {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "command_click_release",
                    expected: "cmd-click fallback only when selection is inactive",
                    actual: suppressCommandPathHover ? "suppressed" : "not_cmd_click",
                    data: [
                        "flags": debugModifierString(modifierFlags),
                        "ghostty_consumed": ghosttyConsumed,
                        "point_x": point.x,
                        "point_y": point.y,
                        "resolved_point_x": resolvedPoint?.x ?? -1,
                        "resolved_point_y": resolvedPoint?.y ?? -1,
                        "suppress_path_hover": suppressCommandPathHover
                    ]
                )
            }
#endif
            return nil
        }

        // Refresh ghostty's cached mouse position so quicklook_word reads
        // up-to-date coordinates (mouseDown skips pos update on double-click).
        if let resolvedPoint {
            ghostty_surface_mouse_pos(
                surface,
                resolvedPoint.x,
                bounds.height - resolvedPoint.y,
                modsFromFlags(modifierFlags)
            )
        }

        guard let resolution = resolveWordUnderCursorPath(at: resolvedPoint) else {
#if DEBUG
            runtimeDebugLog(
                hypothesisID: "h2",
                name: "command_click_release",
                expected: "cmd-click should resolve the token under the pointer",
                actual: "no_resolution",
                data: [
                    "flags": debugModifierString(modifierFlags),
                    "ghostty_consumed": ghosttyConsumed,
                    "point_x": point.x,
                    "point_y": point.y,
                    "resolved_point_x": resolvedPoint?.x ?? -1,
                    "resolved_point_y": resolvedPoint?.y ?? -1
                ]
            )
#endif
            return nil
        }
        guard !ghosttyConsumed || resolution.source == .snapshot else {
#if DEBUG
            var payload: [String: Any] = [
                "flags": debugModifierString(modifierFlags),
                "ghostty_consumed": ghosttyConsumed,
                "point_x": point.x,
                "point_y": point.y,
                "resolved_point_x": resolvedPoint?.x ?? -1,
                "resolved_point_y": resolvedPoint?.y ?? -1,
                "suppress_path_hover": suppressCommandPathHover
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: "h3",
                name: "command_click_release",
                expected: "ghostty-consumed clicks should only skip fallback for real ghostty targets",
                actual: "consumed_quicklook_resolution_skipped",
                data: payload
            )
#endif
            return nil
        }

        #if DEBUG
        cmuxDebugLog(
            "link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue) consumed=\(ghosttyConsumed ? 1 : 0)"
        )
        var payload: [String: Any] = [
            "flags": debugModifierString(modifierFlags),
            "ghostty_consumed": ghosttyConsumed,
            "point_x": point.x,
            "point_y": point.y,
            "resolved_point_x": resolvedPoint?.x ?? -1,
            "resolved_point_y": resolvedPoint?.y ?? -1,
            "suppress_path_hover": suppressCommandPathHover
        ]
        for (key, value) in runtimeDebugResolutionPayload(resolution) {
            payload[key] = value
        }
        runtimeDebugLog(
            hypothesisID: resolution.source == .snapshot ? "h3" : "h2",
            name: "command_click_release",
            expected: "cmd-click should open the resolved path",
            actual: "opening_resolved_path",
            data: payload
        )
        #endif

        // Remote-surface guard runs before shouldRoute so we never stat a local
        // path on the main thread for a remote workspace. When the cmux route
        // is applicable but split creation fails, fall back to the preferred
        // editor so the click never silently no-ops.
        if let termSurface = terminalSurface,
           let workspace = termSurface.owningWorkspace(),
           !workspace.isRemoteTerminalSurface(termSurface.id),
           CommandClickFileOpenRouter.openInCmux(
               workspace: workspace,
               sourcePanelId: termSurface.id,
               filePath: resolution.path
           ) {
            return resolution
        }

        PreferredEditorSettings.open(URL(fileURLWithPath: resolution.path))
        return resolution
    }

}
