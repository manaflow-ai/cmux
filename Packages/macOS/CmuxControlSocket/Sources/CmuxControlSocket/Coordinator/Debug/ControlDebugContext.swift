public import Foundation

/// The debug/test-only-domain slice of the control-command seam (a constituent
/// of the ``ControlCommandContext`` umbrella).
///
/// Every `debug.*` method this domain serves was compiled only into DEBUG
/// builds (the legacy dispatch cases sat inside `#if DEBUG`), so all
/// requirements are `#if DEBUG`-gated: in release builds this is an empty
/// marker protocol, the coordinator's `handleDebug` returns `nil`, and the
/// methods fall through to the legacy dispatcher's `method_not_found` — the
/// exact release-build behavior the `#if DEBUG` switch cases produced.
///
/// Many witnesses forward to the v1 string-command bodies that the v1
/// `processCommand` dispatch still shares (`set_shortcut`, `read_text`,
/// `panel_snapshot`, …); those return the raw v1 response `String` and the
/// coordinator owns the legacy v2 wrapper's parsing of it.
@MainActor
public protocol ControlDebugContext: AnyObject {
#if DEBUG
    // MARK: - Session-snapshot benchmarks

    /// Runs the DEBUG session-snapshot benchmark for
    /// `debug.session_snapshot_benchmark` (walks AppKit/SwiftUI/terminal-panel
    /// state on the main actor) and bridges its Foundation payload.
    ///
    /// - Parameters:
    ///   - includeScrollback: Whether to capture scrollback in the snapshot.
    ///   - persist: Whether to persist the captured snapshot.
    /// - Returns: The benchmark payload, or `nil` when the app delegate is
    ///   unavailable (the legacy `unavailable` error).
    func controlDebugSessionSnapshotBenchmark(includeScrollback: Bool, persist: Bool) -> JSONValue?

    /// Seeds synthetic scrollback into the workspace snapshot fallback state
    /// for `debug.session_snapshot_seed_scrollback`.
    ///
    /// - Parameter charactersPerTerminal: Characters to seed per terminal.
    /// - Returns: The seeding payload, or `nil` when the app delegate is
    ///   unavailable (the legacy `unavailable` error).
    func controlDebugSessionSnapshotSeedScrollback(charactersPerTerminal: Int) -> JSONValue?

    // MARK: - v1-shared command forwards (raw v1 response strings)

    /// Runs the shared v1 `set_shortcut` body for `debug.shortcut.set`.
    ///
    /// - Parameter arguments: The v1 argument line (`"<name> <combo>"`).
    /// - Returns: The raw v1 response (`"OK"` or an `ERROR:` line).
    func controlDebugSetShortcut(arguments: String) -> String

    /// Runs the shared v1 `simulate_shortcut` body for `debug.shortcut.simulate`.
    ///
    /// - Parameter combo: The shortcut combo to simulate.
    /// - Returns: The raw v1 response.
    func controlDebugSimulateShortcut(combo: String) -> String

    /// Runs the shared v1 `activate_app` body for `debug.app.activate`.
    ///
    /// - Returns: The raw v1 response.
    func controlDebugActivateApp() -> String

    /// Runs the shared v1 `is_terminal_focused` body for
    /// `debug.terminal.is_focused`.
    ///
    /// - Parameter surfaceArgument: The surface id/index argument.
    /// - Returns: The raw v1 response (`"true"`/`"false"` or an `ERROR` line).
    func controlDebugIsTerminalFocused(surfaceArgument: String) -> String

    /// Runs the shared v1 `read_text` body for `debug.terminal.read_text`.
    ///
    /// - Parameter surfaceArgument: The surface id/index argument (may be
    ///   empty for the focused surface).
    /// - Returns: The raw v1 response (`"OK <base64>"` or an `ERROR:` line).
    func controlDebugReadTerminalText(surfaceArgument: String) -> String

    /// Runs the shared v1 `render_stats` body for `debug.terminal.render_stats`.
    ///
    /// - Parameter surfaceArgument: The surface id/index argument.
    /// - Returns: The raw v1 response (`"OK <json>"` or an `ERROR:` line).
    func controlDebugRenderStats(surfaceArgument: String) -> String

    /// Runs the shared v1 `layout_debug` body for `debug.layout`.
    ///
    /// - Returns: The raw v1 response (`"OK <json>"` or an `ERROR:` line).
    func controlDebugLayout() -> String

    /// Runs the shared v1 `bonsplit_underflow_count` body for
    /// `debug.bonsplit_underflow.count`.
    ///
    /// - Returns: The raw v1 response (`"OK <n>"` or an `ERROR:` line).
    func controlDebugBonsplitUnderflowCount() -> String

    /// Runs the shared v1 `reset_bonsplit_underflow_count` body for
    /// `debug.bonsplit_underflow.reset`.
    ///
    /// - Returns: The raw v1 response.
    func controlDebugResetBonsplitUnderflowCount() -> String

    /// Runs the shared v1 `empty_panel_count` body for `debug.empty_panel.count`.
    ///
    /// - Returns: The raw v1 response (`"OK <n>"` or an `ERROR:` line).
    func controlDebugEmptyPanelCount() -> String

    /// Runs the shared v1 `reset_empty_panel_count` body for
    /// `debug.empty_panel.reset`.
    ///
    /// - Returns: The raw v1 response.
    func controlDebugResetEmptyPanelCount() -> String

    /// Runs the shared v1 `focus_from_notification` body for
    /// `debug.notification.focus`.
    ///
    /// - Parameter arguments: The v1 argument line (`"<ws-id>[ <surface-id>]"`).
    /// - Returns: The raw v1 response.
    func controlDebugFocusNotification(arguments: String) -> String

    /// Runs the shared v1 `flash_count` body for `debug.flash.count`.
    ///
    /// - Parameter surfaceArgument: The surface id/index argument.
    /// - Returns: The raw v1 response (`"OK <n>"` or an `ERROR:` line).
    func controlDebugFlashCount(surfaceArgument: String) -> String

    /// Runs the shared v1 `reset_flash_counts` body for `debug.flash.reset`.
    ///
    /// - Returns: The raw v1 response.
    func controlDebugResetFlashCounts() -> String

    /// Runs the shared v1 `panel_snapshot` body for `debug.panel_snapshot`.
    ///
    /// - Parameter arguments: The v1 argument line (`"<surface>[ <label>]"`).
    /// - Returns: The raw v1 response (`"OK <id> <px> <w> <h> <path>"`).
    func controlDebugPanelSnapshot(arguments: String) -> String

    /// Runs the shared v1 `panel_snapshot_reset` body for
    /// `debug.panel_snapshot.reset`.
    ///
    /// - Parameter surfaceArgument: The surface id/index argument.
    /// - Returns: The raw v1 response.
    func controlDebugPanelSnapshotReset(surfaceArgument: String) -> String

    /// Runs the shared v1 `screenshot` body for `debug.window.screenshot`.
    ///
    /// - Parameter label: The optional screenshot label (may be empty).
    /// - Returns: The raw v1 response (`"OK <id> <path>"` or an `ERROR:` line).
    func controlDebugCaptureScreenshot(label: String) -> String

    /// Shows the canvas Command+scroll discovery hint for
    /// `debug.canvas.command_scroll_hint`.
    ///
    /// - Parameter routing: Optional workspace/window routing selectors.
    /// - Returns: The canvas action outcome.
    func controlDebugShowCanvasCommandScrollHint(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution

    /// Opens the debug spinner gallery window for `debug.spinner_gallery.show`.
    func controlDebugShowSpinnerGallery()

    // MARK: - Live app/UI state

    /// Inserts text at the key window's first responder for `debug.type`
    /// (activating the app first when the focus policy allows it).
    ///
    /// - Parameter text: The text to insert (raw, may be empty).
    /// - Returns: The insertion outcome.
    func controlDebugTypeText(_ text: String) -> ControlDebugTypeResolution

    /// Whether the controller's primary `TabManager` is available (the
    /// `guard let tabManager` precondition several legacy debug bodies ran
    /// before parsing their params).
    func controlDebugTabManagerAvailable() -> Bool

    /// Installs the inline text-box fixture on a terminal panel for
    /// `debug.textbox.inline_fixture` and snapshots the resulting state.
    ///
    /// - Parameters:
    ///   - target: The trimmed surface id/index argument, or `nil` for the
    ///     selected terminal panel.
    ///   - path: The trimmed local file path to attach, or `nil` for none.
    ///   - beforeText: Text placed before the attachment.
    ///   - afterText: Text placed after the attachment.
    /// - Returns: The fixture snapshot, or `nil` when the terminal panel was
    ///   not found (the legacy `not_found` error).
    func controlDebugTextBoxInlineFixture(
        target: String?,
        path: String?,
        beforeText: String,
        afterText: String
    ) -> ControlDebugTextBoxFixtureSnapshot?

    /// Performs one scripted text-box interaction for `debug.textbox.interact`
    /// (activating the app first when the focus policy allows it).
    ///
    /// - Parameters:
    ///   - target: The trimmed surface id/index argument, or `nil` for the
    ///     selected terminal panel.
    ///   - action: The interaction action token.
    /// - Returns: The interaction state, or `nil` when the terminal text box
    ///   was not found (the legacy `not_found` error).
    func controlDebugTextBoxInteract(target: String?, action: String) -> ControlDebugTextBoxInteraction?

    /// Posts one command-palette notification for the
    /// `debug.command_palette.toggle` / `rename_tab.open` /
    /// `rename_input.interact` / `rename_input.delete_backward` family.
    ///
    /// - Parameters:
    ///   - event: Which palette notification to post.
    ///   - windowID: The explicit target window, or `nil` for the key/main
    ///     window.
    /// - Returns: `false` when `windowID` was given but no such window exists
    ///   (the legacy `not_found` error); `true` once the notification posted.
    func controlDebugPostCommandPaletteEvent(_ event: ControlDebugCommandPaletteEvent, windowID: UUID?) -> Bool

    /// Whether the command palette is visible in a window for
    /// `debug.command_palette.visible` / `.selection` / `.results`.
    ///
    /// - Parameter windowID: The window to inspect.
    /// - Returns: The visibility (missing window reads as `false`, as the
    ///   legacy `?? false` did).
    func controlDebugCommandPaletteVisible(windowID: UUID) -> Bool

    /// The command palette's selected row index in a window for
    /// `debug.command_palette.selection` / `.results`.
    ///
    /// - Parameter windowID: The window to inspect.
    /// - Returns: The selection index (missing window reads as `0`).
    func controlDebugCommandPaletteSelectionIndex(windowID: UUID) -> Int

    /// Snapshots the command palette's query/mode/results in a window for
    /// `debug.command_palette.results`.
    ///
    /// - Parameter windowID: The window to inspect.
    /// - Returns: The snapshot (missing window reads as the empty snapshot).
    func controlDebugCommandPaletteSnapshot(windowID: UUID) -> ControlDebugCommandPaletteSnapshot

    /// Reads the rename-input field editor's selection in a window for
    /// `debug.command_palette.rename_input.selection`.
    ///
    /// - Parameter windowID: The window to inspect.
    /// - Returns: The selection resolution.
    func controlDebugCommandPaletteRenameInputSelection(windowID: UUID) -> ControlDebugRenameInputSelectionResolution

    /// Optionally writes, then reads, the rename-input select-all-on-focus
    /// setting for `debug.command_palette.rename_input.select_all`.
    ///
    /// - Parameter enabled: The new value to store first, or `nil` to only
    ///   read.
    /// - Returns: The setting's effective value after any write.
    func controlDebugCommandPaletteRenameSelectAll(updating enabled: Bool?) -> Bool

    /// The surface id whose browser address bar currently has focus, for
    /// `debug.browser.address_bar_focused`.
    ///
    /// - Returns: The focused surface id, or `nil` when none.
    func controlDebugFocusedBrowserAddressBarSurfaceID() -> UUID?

    /// Runs the legacy `debug.browser.favicon` body for the given params.
    ///
    /// This is a documented single-method passthrough: the body resolves its
    /// browser panel through the still-shared `v2BrowserWithPanel` helper
    /// (used by the entire `browser.*` domain), so the param resolution and
    /// every error shape stay app-side and byte-identical.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The full call result.
    func controlDebugBrowserFavicon(params: [String: JSONValue]) -> ControlCallResult

    /// Reveals and focuses the right sidebar for `debug.right_sidebar.focus`.
    ///
    /// - Parameters:
    ///   - modeName: The requested sidebar mode raw value, or `nil` for the
    ///     app's default (`dock`).
    ///   - windowID: The explicit target window, or `nil` for the key/main
    ///     window.
    ///   - focusFirstItem: Whether to focus the first sidebar item.
    /// - Returns: The reveal resolution.
    func controlDebugRightSidebarFocus(
        modeName: String?,
        windowID: UUID?,
        focusFirstItem: Bool
    ) -> ControlDebugRightSidebarFocusResolution

    /// The sidebar visibility of a window for `debug.sidebar.visible`.
    ///
    /// - Parameter windowID: The window to inspect.
    /// - Returns: The visibility, or `nil` when the window was not found (the
    ///   legacy `not_found` error).
    func controlDebugSidebarVisibility(windowID: UUID) -> Bool?

    /// Simulates a file drop onto a terminal for
    /// `debug.terminal.simulate_file_drop`.
    ///
    /// - Parameters:
    ///   - surfaceArgument: The surface id/index argument.
    ///   - paths: The trimmed, non-empty file paths to drop.
    ///   - route: The drop route to simulate.
    ///   - payloadKind: The pasteboard payload kind to synthesize.
    /// - Returns: The simulation resolution.
    func controlDebugSimulateTerminalFileDrop(
        surfaceArgument: String,
        paths: [String],
        route: ControlDebugFileDropRoute,
        payloadKind: ControlDebugFileDropPayloadKind
    ) -> ControlDebugFileDropResolution

    /// Snapshots the terminal-window portal registry's counters for
    /// `debug.portal.stats`.
    ///
    /// - Returns: The stats payload (`nil` only if the counter dictionary ever
    ///   failed to bridge to JSON, which its `String`/`Int` leaves preclude).
    func controlDebugPortalStats() -> JSONValue?
#endif
}
