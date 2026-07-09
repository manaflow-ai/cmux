import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxCanvasUI
import CmuxControlSocket
import CmuxFoundation
import CmuxSettings
import CmuxShortcuts
import Foundation
import CmuxTerminal

/// The debug-domain witnesses are the byte-faithful bodies of the former
/// `v2Debug*` dispatchers `processV2Command` routed (DEBUG builds only), minus
/// the per-read `v2MainSync` hops: the coordinator already runs on the main
/// actor inside the socket-command policy scope, so each hop was a no-op.
///
/// Two witness families:
/// - **Lifted state reads/mutations** (`debug.type`, text-box fixtures, the
///   command palette, right sidebar, file-drop simulation): the legacy
///   `v2MainSync` content runs here verbatim against `NSApp`/`AppDelegate`/
///   `TabManager` and crosses the seam as Sendable snapshots.
/// - **v1 debug/test bodies** (`set_shortcut`, `simulate_shortcut`,
///   `read_terminal_text`, `render_stats`, `panel_snapshot`, `layout_debug`,
///   `screenshot`, the flash/empty-panel/bonsplit counters, …): the v1 string
///   bodies were drained out of the `TerminalController.swift` god file into
///   this conformance file. They stay in the app target (not the
///   `CmuxControlSocket` package) because they are irreducibly app-coupled
///   (`NSApp`/`NSWindow`/`CGImage`/responder chains/ghostty surfaces); the v1
///   `processCommand` switch routes them through
///   ``ControlCommandCoordinator/handleDebugV1(command:args:)``, whose witnesses
///   forward to these verbatim bodies and return the raw v1 response for the
///   coordinator to parse exactly as the legacy dispatch did. The shared
///   resolvers they call (`resolveTab`, `resolveSurfaceId`, `orderedPanels`,
///   `resolveTerminalPanel`, `prepareWindowForSyntheticInput`) stay in
///   `TerminalController.swift` because non-relocated callers also use them.
///
/// In release builds `ControlDebugContext` has no requirements, so the
/// conformance is an empty extension — matching the legacy `#if DEBUG` switch
/// cases that compiled the whole domain out.
#if DEBUG
@MainActor
func debugShowCanvasCommandScrollHint(in workspace: Workspace) -> Bool {
    guard workspace.layoutMode == .canvas,
          let rootView = workspace.canvasModel.viewport as? CanvasRootView else {
        return false
    }
    rootView.debugShowCommandScrollHint()
    return true
}
#endif

extension TerminalController: ControlDebugContext {
#if DEBUG
    // MARK: - Session-snapshot benchmarks

    func controlDebugSessionSnapshotBenchmark(includeScrollback: Bool, persist: Bool) -> JSONValue? {
        // Snapshot capture walks AppKit, SwiftUI, and terminal-panel state, so
        // this DEBUG-only benchmark must run synchronously on the main actor.
        guard let payload = AppDelegate.shared?.debugBenchmarkSessionSnapshot(
            includeScrollback: includeScrollback,
            persist: persist
        ) else {
            return nil
        }
        // The benchmark payload is JSON-safe by construction; a bridge failure
        // would have been the legacy encode_error and collapses to the same
        // `unavailable` outcome here (the `controlDebugTerminals` precedent).
        return JSONValue(foundationObject: payload)
    }

    func controlDebugSessionSnapshotSeedScrollback(charactersPerTerminal: Int) -> JSONValue? {
        // Synthetic scrollback seeding mutates workspace snapshot fallback
        // state, which is owned by the main-thread workspace graph.
        guard let payload = AppDelegate.shared?.debugSeedSessionSnapshotScrollback(
            charactersPerTerminal: charactersPerTerminal
        ) else {
            return nil
        }
        return JSONValue(foundationObject: payload)
    }

    // MARK: - v1-shared forwards (bodies stay in TerminalController.swift)

    func controlDebugSetShortcut(arguments: String) -> String {
        KeyboardShortcutSettings.applyDebugSetShortcutCommand(arguments)
    }

    func controlDebugSimulateShortcut(combo: String) -> String { simulateShortcut(combo) }

    func controlDebugActivateApp() -> String { activateApp() }

    func controlDebugIsTerminalFocused(surfaceArgument: String) -> String {
        isTerminalFocused(surfaceArgument)
    }

    func controlDebugReadTerminalText(surfaceArgument: String) -> String {
        readTerminalText(surfaceArgument)
    }

    func controlDebugRenderStats(surfaceArgument: String) -> String {
        renderStats(surfaceArgument)
    }

    func controlDebugLayout() -> String { layoutDebug() }

    func controlDebugBonsplitUnderflowCount() -> String { bonsplitUnderflowCount() }

    func controlDebugResetBonsplitUnderflowCount() -> String { resetBonsplitUnderflowCount() }

    func controlDebugEmptyPanelCount() -> String { emptyPanelCount() }

    func controlDebugResetEmptyPanelCount() -> String { resetEmptyPanelCount() }

    func controlDebugFocusNotification(arguments: String) -> String {
        focusFromNotification(arguments)
    }

    func controlDebugFlashCount(surfaceArgument: String) -> String { flashCount(surfaceArgument) }

    func controlDebugResetFlashCounts() -> String { resetFlashCounts() }

    func controlDebugPanelSnapshot(arguments: String) -> String { panelSnapshot(arguments) }

    func controlDebugPanelSnapshotReset(surfaceArgument: String) -> String {
        panelSnapshotReset(surfaceArgument)
    }

    func controlDebugCaptureScreenshot(label: String) -> String { captureScreenshot(label) }

    func controlDebugShowCanvasCommandScrollHint(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution {
        guard let workspace = resolveCanvasWorkspace(routing: routing) else {
            return .workspaceNotFound
        }
        guard workspace.layoutMode == .canvas else {
            return .notCanvasMode
        }
        guard debugShowCanvasCommandScrollHint(in: workspace) else {
            return .viewportUnavailable
        }
        return .ok(mode: workspace.layoutMode.rawValue)
    }

    // MARK: - debug.type

    func controlDebugTypeText(_ text: String) -> ControlDebugTypeResolution {
        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
            ?? NSApp.windows.first else {
            return .noWindow
        }
        if Self.socketCommandAllowsInAppFocusMutations() {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        guard let fr = window.firstResponder else {
            return .noFirstResponder
        }
        if let client = fr as? NSTextInputClient {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return .inserted
        }
        fr.insertText(text)
        return .inserted
    }

    func controlDebugSimulateMarkedText(_ text: String) -> ControlDebugTypeResolution {
        guard let window = debugFocusedTerminalWindow() else { return .noWindow }
        if Self.socketCommandAllowsInAppFocusMutations() {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        guard let client = window.firstResponder as? NSTextInputClient else {
            return .noFirstResponder
        }
        client.setMarkedText(
            text,
            selectedRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        return .inserted
    }

    func controlDebugSimulateUnmarkText() -> ControlDebugTypeResolution {
        guard let window = debugFocusedTerminalWindow() else { return .noWindow }
        if Self.socketCommandAllowsInAppFocusMutations() {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        guard let client = window.firstResponder as? NSTextInputClient else {
            return .noFirstResponder
        }
        client.unmarkText()
        return .inserted
    }

    private func debugFocusedTerminalWindow() -> NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
            ?? NSApp.windows.first
    }

    // MARK: - debug.textbox.*

    func controlDebugTabManagerAvailable() -> Bool {
        tabManager != nil
    }

    func controlDebugTextBoxInlineFixture(
        target: String?,
        path: String?,
        beforeText: String,
        afterText: String
    ) -> ControlDebugTextBoxFixtureSnapshot? {
        guard let tabManager else { return nil }
        let panel: TerminalPanel?
        if let target, !target.isEmpty {
            panel = resolveTerminalPanel(from: target, tabManager: tabManager)
        } else {
            panel = tabManager.selectedTerminalPanel
        }

        guard let panel else {
            return nil
        }

        let url = path.map { URL(fileURLWithPath: $0).standardizedFileURL }
        _ = panel.installDebugTextBoxInlineFixture(
            localURL: url,
            beforeText: beforeText,
            afterText: afterText
        )
        let textView = panel.textBoxInputView
        return ControlDebugTextBoxFixtureSnapshot(
            surfaceID: panel.id,
            path: url?.path ?? "",
            isTextBoxActive: panel.isTextBoxActive,
            hasTextView: textView != nil,
            textViewHasWindow: textView?.window != nil,
            textViewMatchesPanelWindow: textView?.window === panel.hostedView.window,
            panelText: panel.textBoxContent,
            panelAttachmentCount: panel.textBoxAttachments.count,
            textViewText: textView?.plainText() ?? "",
            textViewAttachmentCount: textView?.inlineAttachments().count ?? 0
        )
    }

    func controlDebugTextBoxInteract(target: String?, action: String) -> ControlDebugTextBoxInteraction? {
        guard let tabManager else { return nil }
        let panel: TerminalPanel?
        if let target, !target.isEmpty {
            panel = resolveTerminalPanel(from: target, tabManager: tabManager)
        } else {
            panel = tabManager.selectedTerminalPanel
        }

        guard let panel,
              let textView = panel.textBoxInputView,
              let window = textView.window else {
            return nil
        }

        if Self.socketCommandAllowsInAppFocusMutations() {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        let state = textView.performControlInteraction(action: action)
        // `performControlInteraction` emits String/Bool/Int leaves only, so the bridge
        // cannot fail; the empty-object fallback keeps the conversion total.
        return ControlDebugTextBoxInteraction(
            surfaceID: panel.id,
            state: JSONValue(foundationObject: state) ?? .object([:])
        )
    }

    // MARK: - debug.command_palette.*

    func controlDebugPostCommandPaletteEvent(
        _ event: ControlDebugCommandPaletteEvent,
        windowID: UUID?
    ) -> Bool {
        let targetWindow: NSWindow?
        if let windowID {
            guard let window = appEnvironment?.windowRegistry.mainWindow(for: windowID) else {
                return false
            }
            targetWindow = window
        } else {
            targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        }
        let name: Notification.Name
        switch event {
        case .toggle:
            name = .commandPaletteToggleRequested
        case .renameTabOpen:
            name = .commandPaletteRenameTabRequested
        case .renameInputInteraction:
            name = .commandPaletteRenameInputInteractionRequested
        case .renameInputDeleteBackward:
            name = .commandPaletteRenameInputDeleteBackwardRequested
        }
        NotificationCenter.default.post(name: name, object: targetWindow)
        return true
    }

    func controlDebugCommandPaletteVisible(windowID: UUID) -> Bool {
        AppDelegate.shared?.isCommandPaletteVisible(windowId: windowID) ?? false
    }

    func controlDebugCommandPaletteSelectionIndex(windowID: UUID) -> Int {
        AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowID) ?? 0
    }

    func controlDebugCommandPaletteSnapshot(windowID: UUID) -> ControlDebugCommandPaletteSnapshot {
        let snapshot = AppDelegate.shared?.commandPaletteSnapshot(windowId: windowID) ?? .empty
        return ControlDebugCommandPaletteSnapshot(
            query: snapshot.query,
            mode: snapshot.mode,
            results: snapshot.results.map { row in
                ControlDebugCommandPaletteResult(
                    commandID: row.commandId,
                    title: row.title,
                    shortcutHint: row.shortcutHint,
                    trailingLabel: row.trailingLabel,
                    score: row.score
                )
            }
        )
    }

    func controlDebugCommandPaletteRenameInputSelection(
        windowID: UUID
    ) -> ControlDebugRenameInputSelectionResolution {
        guard let window = appEnvironment?.windowRegistry.mainWindow(for: windowID) else {
            return .windowNotFound
        }
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
            return .inactive
        }
        let selectedRange = editor.selectedRange()
        let textLength = (editor.string as NSString).length
        return .active(
            location: selectedRange.location,
            length: selectedRange.length,
            textLength: textLength
        )
    }

    func controlDebugCommandPaletteRenameSelectAll(updating enabled: Bool?) -> Bool {
        let store = CommandPaletteSettingsStore(defaults: .standard)
        if let enabled {
            store.setRenameSelectsExistingName(enabled)
        }
        return store.renameSelectsAllOnFocus
    }

    // MARK: - debug.browser.*

    func controlDebugFocusedBrowserAddressBarSurfaceID() -> UUID? {
        AppDelegate.shared?.focusedBrowserAddressBarPanelId()
    }

    func controlDebugBrowserFavicon(params: [String: JSONValue]) -> ControlCallResult {
        // Documented passthrough: panel resolution lives in the still-shared
        // `v2BrowserWithPanel` (the whole `browser.*` domain's resolver), so
        // the legacy `[String: Any]` params are reconstructed exactly
        // (`foundationObject` is the inverse of the dispatcher's bridging) and
        // the favicon body runs verbatim.
        let result = v2BrowserWithPanel(params: params.mapValues(\.foundationObject)) { _, workspace, surfaceId, browserPanel in
            let workspaceId = workspace.id
            let pngData = browserPanel.faviconPNGData
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "has_favicon": pngData != nil,
                "png_base64": pngData?.base64EncodedString() ?? "",
                "current_url": v2OrNull(browserPanel.currentURL?.absoluteString)
            ])
        }
        switch result {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(
                code: code,
                message: message,
                data: data.flatMap { JSONValue(foundationObject: $0) }
            )
        }
    }

    // MARK: - debug.right_sidebar.focus / debug.sidebar.visible

    func controlDebugRightSidebarFocus(
        modeName: String?,
        windowID: UUID?,
        focusFirstItem: Bool
    ) -> ControlDebugRightSidebarFocusResolution {
        let resolvedModeName = modeName ?? RightSidebarMode.dock.rawValue
        guard let mode = RightSidebarMode(rawValue: resolvedModeName) else {
            return .invalidMode(resolvedModeName)
        }
        let preferredWindow: NSWindow?
        if let windowID {
            preferredWindow = appEnvironment?.windowRegistry.mainWindow(for: windowID)
            guard preferredWindow != nil else {
                return .windowNotFound
            }
        } else {
            preferredWindow = NSApp.keyWindow ?? NSApp.mainWindow
        }
        let result = AppDelegate.shared?.debugRevealRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: focusFirstItem,
            preferredWindow: preferredWindow
        )
        return .revealed(ControlDebugRightSidebarFocusState(
            revealed: result?.revealed ?? false,
            focusApplied: result?.focusApplied ?? false,
            contextFound: result?.contextFound ?? false,
            stateFound: result?.stateFound ?? false,
            visible: result?.visible ?? false,
            activeMode: result?.activeMode,
            mode: mode.rawValue
        ))
    }

    func controlDebugSidebarVisibility(windowID: UUID) -> Bool? {
        AppDelegate.shared?.sidebarVisibility(windowId: windowID)
    }

    // MARK: - debug.terminal.simulate_file_drop

    func controlDebugSimulateTerminalFileDrop(
        surfaceArgument: String,
        paths: [String],
        route: ControlDebugFileDropRoute,
        payloadKind: ControlDebugFileDropPayloadKind
    ) -> ControlDebugFileDropResolution {
        guard let tabManager,
              let panel = resolveTerminalPanel(from: surfaceArgument, tabManager: tabManager) else {
            return .panelNotFound
        }

        switch route {
        case .terminal:
            let handled = panel.hostedView.debugSimulateFileDrop(
                paths: paths,
                asImageData: payloadKind == .imageData
            )
            return .terminalDrop(handled: handled)
        case .textDestination:
            guard payloadKind == .fileURLs else {
                return .imageDataRequiresTerminalRoute
            }
            guard let workspace = tabManager.tabs.first(where: { $0.id == panel.workspaceId }) else {
                return .workspaceNotFound(workspaceID: panel.workspaceId)
            }
            let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let handled = FileDropTextDropController.performTerminalFileDrop(
                workspace: workspace,
                panelId: panel.id,
                hostedView: panel.hostedView,
                urls: urls,
                window: panel.surface.uiWindow
            )
            return .textDestinationDrop(handled: handled)
        }
    }

    // MARK: - debug.portal.stats

    func controlDebugPortalStats() -> JSONValue? {
        JSONValue(foundationObject: TerminalWindowPortalRegistry.debugPortalStats())
    }

    // MARK: - v1-only synthetic-input / drag-overlay probes
    //
    // These commands exist only on the v1 line protocol (no v2 method). Each
    // witness carries the irreducible app-coupled body (`NSApp`/`NSWindow`/
    // `NSPasteboard`/`NSView` hit-testing/ghostty surfaces) from the former
    // `TerminalController` v1 dispatchers.
    //
    // The pure halves of five of them — the `[external|local]`,
    // `[active|inactive]`, `[deferred|direct]` token parsing, the
    // `"<x 0-1> <y 0-1>"` coordinate parse/validation, the verbatim usage-error
    // strings, and the response formatting — were drained into the
    // `CmuxControlSocket` coordinator
    // (``ControlCommandCoordinator/debugOverlayDropGateV1(_:)`` and its four
    // siblings), so `controlDebugOverlayDropGate`/`controlDebugSidebarOverlayGate`
    // /`controlDebugTerminalDropOverlayProbe`/`controlDebugDropHitTest`/
    // `controlDebugDragHitChain` now take already-parsed typed inputs and do
    // only the live read. `simulate_type` and `simulate_file_drop` are split
    // the same way: their argument trim/empty-check/escape-decode and
    // `<id|idx> <path…>` split (plus the usage `ERROR` strings and the
    // `OK`/failure formatting) drained into
    // ``ControlCommandCoordinator/debugSimulateTypeV1(_:)`` /
    // ``ControlCommandCoordinator/debugSimulateFileDropV1(_:)``, so
    // `controlDebugSimulateType` now takes already-decoded text and returns a
    // typed ``ControlDebugTypeResolution``, and `controlDebugSimulateFileDrop`
    // takes the parsed `target`/`paths` and returns a typed
    // ``ControlDebugSimulateFileDropResolution``. The remaining witnesses (the
    // `seed_drag_pasteboard_*` family, `clear_drag_pasteboard`,
    // `overlay_hit_gate`, `portal_hit_gate`) keep their whole body: the gate
    // pair parses to an AppKit `NSEvent.EventType`, which the AppKit-free
    // control-plane package cannot host, the seed family maps to AppKit
    // `NSPasteboard.PasteboardType`, and `clear_drag_pasteboard` has no decision
    // step. They return the raw v1 response string the legacy `processCommand`
    // cases produced.
    // `simulateShortcut` (a v1-shared body that stays in
    // `TerminalController.swift`) shares `prepareWindowForSyntheticInput`, which
    // is therefore `internal`.

    func controlDebugSimulateType(decodedText text: String) -> ControlDebugTypeResolution {
        // The raw-argument trim, the empty-text usage `ERROR`, and the
        // backslash-escape decoding live in the coordinator's
        // `debugSimulateTypeV1(_:)`; this witness does only the live AppKit
        // first-responder insert. `prepareWindowForSyntheticInput` is shared
        // with `simulate_shortcut`, so it stays in `TerminalController.swift`.
        var resolution = ControlDebugTypeResolution.noWindow
        v2MainSync {
            // Like simulate_shortcut, prefer a visible window so debug automation doesn't
            // fail during key window transitions.
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else { return }
            prepareWindowForSyntheticInput(window)
            guard let fr = window.firstResponder else {
                resolution = .noFirstResponder
                return
            }

            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                resolution = .inserted
                return
            }

            // Fall back to the responder chain insertText action. `fr` is
            // already an `NSResponder` (`window.firstResponder`), so the legacy
            // `as? NSResponder` cast was redundant; dropping it is byte-faithful
            // and clears an always-succeeds warning in this now-tracked file.
            fr.insertText(text)
            resolution = .inserted
        }
        return resolution
    }

    func controlDebugSimulateFileDrop(
        target: String,
        paths: [String]
    ) -> ControlDebugSimulateFileDropResolution {
        // The `<id|idx> <path[|path...]>` argument split, the usage `ERROR`
        // strings, and the `OK`/failure response formatting live in the
        // coordinator's `debugSimulateFileDropV1(_:)`; this witness does only
        // the live `TabManager` availability guard, surface resolution, and the
        // hosted-view drop synthesis.
        guard let tabManager = tabManager else { return .tabManagerUnavailable }

        var resolution = ControlDebugSimulateFileDropResolution.surfaceNotFound
        v2MainSync {
            guard let panel = resolveTerminalPanel(from: target, tabManager: tabManager) else { return }
            resolution = panel.hostedView.debugSimulateFileDrop(paths: paths)
                ? .dropped
                : .dropFailed
        }
        return resolution
    }

    // The drag/drop-overlay + pasteboard probe bodies were relocated to the
    // app-owned `DebugDragOverlayProbes` (held as
    // ``TerminalController/dragOverlayProbes``). Each witness keeps the
    // `v2MainSync` scope hop (which re-establishes the socket-command
    // focus-allowance stack this controller owns) and forwards the inner
    // main-thread work to the probe; the relocated bodies are byte-faithful.

    func controlDebugSeedDragPasteboardTypes(arguments: String) -> String {
        v2MainSync { self.dragOverlayProbes.seedDragPasteboardTypes(arguments: arguments) }
    }

    func controlDebugClearDragPasteboard() -> String {
        v2MainSync { self.dragOverlayProbes.clearDragPasteboard() }
    }

    func controlDebugOverlayHitGate(eventToken: ControlDebugOverlayEventToken) -> Bool {
        v2MainSync { self.dragOverlayProbes.overlayHitGate(eventToken: eventToken) }
    }

    func controlDebugOverlayDropGate(hasLocalDraggingSource: Bool) -> Bool {
        v2MainSync {
            self.dragOverlayProbes.overlayDropGate(hasLocalDraggingSource: hasLocalDraggingSource)
        }
    }

    func controlDebugPortalHitGate(eventToken: ControlDebugOverlayEventToken) -> Bool {
        v2MainSync { self.dragOverlayProbes.portalHitGate(eventToken: eventToken) }
    }

    func controlDebugSidebarOverlayGate(hasSidebarDragState: Bool) -> Bool {
        v2MainSync {
            self.dragOverlayProbes.sidebarOverlayGate(hasSidebarDragState: hasSidebarDragState)
        }
    }

    func controlDebugTerminalDropOverlayProbe(
        useDeferredPath: Bool
    ) -> ControlDebugTerminalDropOverlayProbeResolution {
        // The controller owns the tab-graph resolution (and the
        // `.tabManagerUnavailable`/`.noWorkspace`/`.noPanel` outcomes); the
        // resolved panel's overlay-animation probe + `.probed` packaging live in
        // `DebugDragOverlayProbes`.
        guard let tabManager = tabManager else { return .tabManagerUnavailable }

        var result: ControlDebugTerminalDropOverlayProbeResolution = .noWorkspace
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let workspace = tabManager.tabs.first(where: { $0.id == selectedId }) else {
                return
            }

            let terminalPanel = workspace.focusedTerminalPanel
                ?? orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }.first
            guard let terminalPanel else {
                result = .noPanel
                return
            }

            result = self.dragOverlayProbes.terminalDropOverlayProbe(
                panel: terminalPanel,
                useDeferredPath: useDeferredPath
            )
        }
        return result
    }

    func controlDebugDropHitTest(nx: Double, ny: Double) -> String {
        v2MainSync { self.dragOverlayProbes.dropHitTest(nx: nx, ny: ny) }
    }

    func controlDebugDragHitChain(nx: Double, ny: Double) -> String {
        v2MainSync { self.dragOverlayProbes.dragHitChain(nx: nx, ny: ny) }
    }

    func simulateShortcut(_ args: String) -> String {
        let combo = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combo.isEmpty else {
            return "ERROR: Usage: simulate_shortcut <combo>"
        }
        guard let parsed = ParsedShortcutCombo(combo: combo) else {
            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
        }

        // Stamp at socket-handler arrival so event.timestamp includes any wait
        // before the main-thread event dispatch.
        let requestTimestamp = ProcessInfo.processInfo.systemUptime

        var result = "ERROR: Failed to create event"
        v2MainSync {
            // Prefer the current active-tab-manager window so shortcut simulation stays
            // scoped to the intended window even when NSApp.keyWindow is stale.
            let targetWindow: NSWindow? = {
                if let activeTabManager = self.tabManager,
                   let windowId = appEnvironment?.windowRegistry.windowId(for: activeTabManager),
                   let window = appEnvironment?.windowRegistry.mainWindow(for: windowId) {
                    return window
                }
                return NSApp.keyWindow
                    ?? NSApp.mainWindow
                    ?? NSApp.windows.first(where: { $0.isVisible })
                    ?? NSApp.windows.first
            }()
            prepareWindowForSyntheticInput(targetWindow)
            let windowNumber = targetWindow?.windowNumber ?? 0
            guard let keyDownEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: parsed.modifierFlags,
                timestamp: requestTimestamp,
                windowNumber: windowNumber,
                context: nil,
                characters: parsed.characters,
                charactersIgnoringModifiers: parsed.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: parsed.keyCode
            ) else {
                result = "ERROR: NSEvent.keyEvent returned nil"
                return
            }
            let keyUpEvent = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: parsed.modifierFlags,
                timestamp: requestTimestamp + 0.0001,
                windowNumber: windowNumber,
                context: nil,
                characters: parsed.characters,
                charactersIgnoringModifiers: parsed.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: parsed.keyCode
            )
            // Socket-driven shortcut simulation should reuse the exact same matching logic as the
            // app-level shortcut monitor (so tests are hermetic), while still falling back to the
            // normal responder chain for plain typing.
            if let delegate = AppDelegate.shared, delegate.debugHandleCustomShortcut(event: keyDownEvent) {
                result = "OK"
                return
            }
            NSApp.sendEvent(keyDownEvent)
            if let keyUpEvent {
                NSApp.sendEvent(keyUpEvent)
            }
            result = "OK"
        }
        return result
    }

    func activateApp() -> String {
        v2MainSync {
            _ = appEnvironment?.mainWindowRouter.activateFromSocket()
        }
        return "OK"
    }

    func isTerminalFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_terminal_focused <panel_id|idx>" }

        var result = "false"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "false"
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "false"
                return
            }
            result = terminalPanel.hostedView.isSurfaceViewFirstResponder() ? "true" : "false"
        }
        return result
    }

    func readTerminalText(_ args: String) -> String {
        readTerminalTextBase64(surfaceArg: args)
    }

    func renderStats(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if panelArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: panelArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            let stats = terminalPanel.hostedView.debugRenderStats()
            let payload = RenderStatsResponse(
                panelId: panelId.uuidString,
                drawCount: stats.drawCount,
                lastDrawTime: stats.lastDrawTime,
                metalDrawableCount: stats.metalDrawableCount,
                metalLastDrawableTime: stats.metalLastDrawableTime,
                presentCount: stats.presentCount,
                lastPresentTime: stats.lastPresentTime,
                layerClass: stats.layerClass,
                layerContentsKey: stats.layerContentsKey,
                inWindow: stats.inWindow,
                windowIsKey: stats.windowIsKey,
                windowOcclusionVisible: stats.windowOcclusionVisible,
                appIsActive: stats.appIsActive,
                isActive: stats.isActive,
                desiredFocus: stats.desiredFocus,
                isFirstResponder: stats.isFirstResponder
            )

            guard let line = payload.okResponseLine() else {
                result = "ERROR: Failed to encode render_stats"
                return
            }

            result = line
        }

        return result
    }

    func focusFromNotification(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let tabArg = parts.first ?? ""
        let surfaceArg = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let surfaceId = surfaceArg.isEmpty ? nil : resolveSurfaceId(from: surfaceArg, tab: tab)
            if !surfaceArg.isEmpty && surfaceId == nil {
                result = "ERROR: Surface not found"
                return
            }
            if !tabManager.focusTabFromNotification(tab.id, surfaceId: surfaceId) {
                result = "ERROR: Focus failed"
            }
        }
        return result
    }

    func flashCount(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        var result = "ERROR: Surface not found"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: trimmed, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let count = GhosttySurfaceScrollView.flashCount(for: surfaceId)
            result = "OK \(count)"
        }
        return result
    }

    func resetFlashCounts() -> String {
        v2MainSync {
            GhosttySurfaceScrollView.resetFlashCounts()
        }
        return "OK"
    }

    func panelSnapshotReset(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: panel_snapshot_reset <panel_id|idx>" }

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }
            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            panelSnapshotStore.reset(panelId)
            result = "OK"
        }

        return result
    }

    func panelSnapshot(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: panel_snapshot <panel_id|idx> [label]" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let panelArg = parts.first ?? ""
        let label = parts.count > 1 ? parts[1] : ""

        // Generate unique ID for this snapshot/screenshot
        let destination = ScreenshotDestination(label: label)
        try? FileManager.default.createDirectory(at: destination.directory, withIntermediateDirectories: true)
        let outputPath = destination.fileURL

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            // Capture the terminal's IOSurface directly, avoiding Screen Recording permissions.
            let view = terminalPanel.hostedView
            var cgImage = view.debugCopyIOSurfaceCGImage()
            if cgImage == nil {
                // If the surface is mid-attach we may not have contents yet. Nudge a draw and retry once.
                terminalPanel.surface.forceRefresh(reason: "terminalController.debugCopyIOSurfaceRetry")
                cgImage = view.debugCopyIOSurfaceCGImage()
            }
            guard let cgImage else {
                result = "ERROR: Failed to capture panel image"
                return
            }

            guard let current = PanelSnapshotState(cgImage: cgImage) else {
                result = "ERROR: Failed to read panel pixels"
                return
            }

            let changedPixels = panelSnapshotStore.record(current, for: panelId)

            // Save PNG for postmortem debugging.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                result = "ERROR: Failed to encode PNG"
                return
            }

            do {
                try pngData.write(to: outputPath)
            } catch {
                result = "ERROR: Failed to write file: \(error.localizedDescription)"
                return
            }

            result = "OK \(panelId.uuidString) \(changedPixels) \(current.width) \(current.height) \(outputPath.path)"
        }

        return result
    }

    func layoutDebug() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let layout = tab.bonsplitController.layoutSnapshot()
            var paneFrames: [String: PixelRect] = [:]
            for pane in layout.panes {
                paneFrames[pane.paneId] = pane.frame
            }

            @MainActor
            func splitViewInfos(for view: NSView) -> [LayoutDebugSplitView] {
                var infos: [LayoutDebugSplitView] = []
                var current: NSView? = view
                var depth = 0
                while let v = current, depth < 12 {
                    if let sv = v as? NSSplitView {
                        // The split view can be mid-update during bonsplit structural changes; force a layout
                        // pass so our debug snapshot reflects the real state.
                        sv.layoutSubtreeIfNeeded()
                        let isVertical = sv.isVertical
                        let dividerThickness = Double(sv.dividerThickness)
                        let bounds = PixelRect(from: sv.bounds)
                        let frame = sv.frameInWindow.map { PixelRect(from: $0) }
                        let arranged = sv.arrangedSubviews
                        let arrangedFrames = arranged.compactMap { $0.frameInWindow.map { PixelRect(from: $0) } }

                        // Approximate divider position from the first arranged subview's size.
                        let totalSize: CGFloat = isVertical ? sv.bounds.width : sv.bounds.height
                        let availableSize = max(totalSize - sv.dividerThickness, 0)
                        var normalized: Double? = nil
                        if availableSize > 0, let first = arranged.first {
                            let dividerPos = isVertical ? first.frame.width : first.frame.height
                            normalized = Double(dividerPos / availableSize)
                        }

                        infos.append(LayoutDebugSplitView(
                            isVertical: isVertical,
                            dividerThickness: dividerThickness,
                            bounds: bounds,
                            frame: frame,
                            arrangedSubviewFrames: arrangedFrames,
                            normalizedDividerPosition: normalized
                        ))
                    }
                    current = v.superview
                    depth += 1
                }
                return infos
            }

            let selectedPanels: [LayoutDebugSelectedPanel] = tab.bonsplitController.allPaneIds.map { paneId in
                let paneIdStr = paneId.id.uuidString
                let paneFrame = paneFrames[paneIdStr]
                let selectedTabId = layout.panes.first(where: { $0.paneId == paneIdStr })?.selectedTabId

	                guard let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId) else {
	                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: nil,
	                        panelType: nil,
	                        inWindow: nil,
	                        hidden: nil,
	                        viewFrame: nil,
	                        splitViews: nil
	                    )
	                }

	                guard let panelId = tab.panelIdFromSurfaceId(selectedTab.id),
	                      let panel = tab.panels[panelId] else {
	                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: nil,
	                        panelType: nil,
	                        inWindow: nil,
	                        hidden: nil,
	                        viewFrame: nil,
	                        splitViews: nil
	                    )
	                }

                if let tp = panel as? TerminalPanel {
                    let viewRect = tp.hostedView.frameInWindow.map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: tp.hostedView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: tp.panelType.rawValue,
	                        inWindow: tp.surface.isViewInWindow,
	                        hidden: tp.hostedView.isHiddenOrAncestorHidden,
	                        viewFrame: viewRect,
	                        splitViews: splitViews
	                    )
	                }

                if let bp = panel as? BrowserPanel {
                    let viewRect = bp.webView.frameInWindow.map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: bp.webView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: bp.panelType.rawValue,
	                        inWindow: bp.webView.window != nil,
	                        hidden: bp.webView.isHiddenOrAncestorHidden,
	                        viewFrame: viewRect,
	                        splitViews: splitViews
	                    )
	                }

	                return LayoutDebugSelectedPanel(
	                    paneId: paneIdStr,
	                    paneFrame: paneFrame,
	                    selectedTabId: selectedTabId,
	                    panelId: panelId.uuidString,
	                    panelType: panel.panelType.rawValue,
	                    inWindow: nil,
	                    hidden: nil,
	                    viewFrame: nil,
	                    splitViews: nil
	                )
	            }

            let payload = LayoutDebugResponse(
                layout: layout,
                selectedPanels: selectedPanels,
                mainWindowNumber: NSApp.mainWindow?.windowNumber,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            )

            guard let line = payload.okResponseLine() else {
                result = "ERROR: Failed to encode layout_debug"
                return
            }

            result = line
        }
        return result
    }

    func emptyPanelCount() -> String {
        var result = "OK 0"
        v2MainSync {
            result = "OK \(DebugUIEventCounters.emptyPanelAppearCount)"
        }
        return result
    }

    func resetEmptyPanelCount() -> String {
        v2MainSync {
            DebugUIEventCounters.resetEmptyPanelAppearCount()
        }
        return "OK"
    }

    func bonsplitUnderflowCount() -> String {
        var result = "OK 0"
        v2MainSync {
#if DEBUG
            result = "OK \(BonsplitDebugCounters.arrangedSubviewUnderflowCount)"
#else
            result = "OK 0"
#endif
        }
        return result
    }

    func resetBonsplitUnderflowCount() -> String {
        v2MainSync {
#if DEBUG
            BonsplitDebugCounters.reset()
#endif
        }
        return "OK"
    }

    func captureScreenshot(_ args: String) -> String {
        // Parse optional label from args
        let label = args.trimmingCharacters(in: .whitespacesAndNewlines)

        // Generate unique ID for this screenshot
        let destination = ScreenshotDestination(label: label)
        let screenshotId = destination.id

        // Determine output path
        try? FileManager.default.createDirectory(at: destination.directory, withIntermediateDirectories: true)
        let outputPath = destination.fileURL

        // Capture the main window on main thread
        var captureError: String?
        v2MainSync {
            captureError = self.debugWindowScreenshotCapture.captureMainWindowPNG(to: outputPath)
        }

        if let error = captureError {
            return "ERROR: \(error)"
        }

        // Return OK with screenshot ID and path for easy reference
        return "OK \(screenshotId) \(outputPath.path)"
    }
#endif
}
