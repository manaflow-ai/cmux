import AppKit
import Bonsplit
import Carbon.HIToolbox
import CmuxControlSocket
import CmuxSettings
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

    func controlDebugSetShortcut(arguments: String) -> String { setShortcut(arguments) }

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
        let state = textView.debugInteract(action: action)
        // `debugInteract` emits String/Bool/Int leaves only, so the bridge
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
            guard let window = AppDelegate.shared?.mainWindow(for: windowID) else {
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
        guard let window = AppDelegate.shared?.mainWindow(for: windowID) else {
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
        if let enabled {
            UserDefaults.standard.set(
                enabled,
                forKey: AppCatalogSection().renameSelectsExistingName.userDefaultsKey
            )
        }
        return CommandPaletteSettingsStore(defaults: .standard).renameSelectsAllOnFocus
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
        let result = v2BrowserWithPanel(params: params.mapValues(\.foundationObject)) { _, ws, surfaceId, browserPanel in
            let pngData = browserPanel.faviconPNGData
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
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
            preferredWindow = AppDelegate.shared?.mainWindow(for: windowID)
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

    func controlDebugSeedDragPasteboardTypes(arguments: String) -> String {
        let raw = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        let tokens = raw
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        var types: [NSPasteboard.PasteboardType] = []
        for token in tokens {
            guard let mapped = Self.dragPasteboardType(from: token) else {
                return "ERROR: Unknown drag type '\(token)'"
            }
            if !types.contains(mapped) {
                types.append(mapped)
            }
        }

        v2MainSync {
            _ = NSPasteboard(name: .drag).declareTypes(types, owner: nil)
        }
        return "OK"
    }

    func controlDebugClearDragPasteboard() -> String {
        v2MainSync {
            _ = NSPasteboard(name: .drag).clearContents()
        }
        return "OK"
    }

    func controlDebugOverlayHitGate(eventToken: ControlDebugOverlayEventToken) -> Bool {
        let eventType = Self.eventType(for: eventToken)
        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }
        return shouldCapture
    }

    func controlDebugOverlayDropGate(hasLocalDraggingSource: Bool) -> Bool {
        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: pb.types,
                hasLocalDraggingSource: hasLocalDraggingSource
            )
        }
        return shouldCapture
    }

    func controlDebugPortalHitGate(eventToken: ControlDebugOverlayEventToken) -> Bool {
        let eventType = Self.eventType(for: eventToken)
        var shouldPassThrough = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }
        return shouldPassThrough
    }

    func controlDebugSidebarOverlayGate(hasSidebarDragState: Bool) -> Bool {
        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
                hasSidebarDragState: hasSidebarDragState,
                pasteboardTypes: pb.types
            )
        }
        return shouldCapture
    }

    func controlDebugTerminalDropOverlayProbe(
        useDeferredPath: Bool
    ) -> ControlDebugTerminalDropOverlayProbeResolution {
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

            let probe = terminalPanel.hostedView.debugProbeDropOverlayAnimation(
                useDeferredPath: useDeferredPath
            )
            result = .probed(
                before: probe.before,
                after: probe.after,
                boundsWidth: Double(probe.bounds.width),
                boundsHeight: Double(probe.bounds.height)
            )
        }
        return result
    }

    /// Hit-tests the file-drop overlay's coordinate-to-terminal mapping.
    /// Takes normalised (0-1) x,y within the content area where (0,0) is the
    /// top-left corner and (1,1) is the bottom-right corner.  Returns the
    /// surface UUID of the terminal under that point, or "none".
    func controlDebugDropHitTest(nx: Double, ny: Double) -> String {
        var result = "ERROR: No window"
        v2MainSync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            // Convert normalized top-left coordinates into a window point.
            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )
            let windowPoint = themeFrame.convert(pointInTheme, to: nil)

            if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView,
               let terminal = overlay.terminalUnderPoint(windowPoint),
               let surfaceId = terminal.terminalSurface?.id {
                result = surfaceId.uuidString.uppercased()
                return
            }

            result = "none"
        }
        return result
    }

    /// Return the hit-test chain at normalized (0-1) coordinates in the main window's
    /// content area. Used by regression tests to detect root-level drag destinations
    /// shadowing pane-local Bonsplit drop targets.
    func controlDebugDragHitChain(nx: Double, ny: Double) -> String {
        var result = "ERROR: No window"
        v2MainSync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )

            let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView
            if let overlay { overlay.isHidden = true }
            defer { overlay?.isHidden = false }

            guard let hit = themeFrame.hitTest(pointInTheme) else {
                result = "none"
                return
            }

            var chain: [String] = []
            var current: NSView? = hit
            var depth = 0
            while let view = current, depth < 8 {
                chain.append(Self.debugDragHitViewDescriptor(view))
                current = view.superview
                depth += 1
            }
            result = chain.joined(separator: "->")
        }
        return result
    }

    // MARK: - v1-only probe helpers (relocated with their sole callers)

    /// Maps a recognized overlay-gate event token (the token recognition + the
    /// usage/unknown `ERROR` strings now live in the `CmuxControlSocket`
    /// coordinator) to its `NSEvent.EventType`, with `.none` resolving to `nil`.
    /// This is the irreducible AppKit half the control-plane package cannot host.
    private static func eventType(for token: ControlDebugOverlayEventToken) -> NSEvent.EventType? {
        switch token {
        case .leftMouseDragged: return .leftMouseDragged
        case .rightMouseDragged: return .rightMouseDragged
        case .otherMouseDragged: return .otherMouseDragged
        case .mouseMoved: return .mouseMoved
        case .mouseEntered: return .mouseEntered
        case .mouseExited: return .mouseExited
        case .flagsChanged: return .flagsChanged
        case .cursorUpdate: return .cursorUpdate
        case .appKitDefined: return .appKitDefined
        case .systemDefined: return .systemDefined
        case .applicationDefined: return .applicationDefined
        case .periodic: return .periodic
        case .leftMouseDown: return .leftMouseDown
        case .leftMouseUp: return .leftMouseUp
        case .rightMouseDown: return .rightMouseDown
        case .rightMouseUp: return .rightMouseUp
        case .otherMouseDown: return .otherMouseDown
        case .otherMouseUp: return .otherMouseUp
        case .scrollWheel: return .scrollWheel
        case .none: return nil
        }
    }

    /// Maps a drag-type token (named alias or explicit UTI) to the matching
    /// pasteboard type, or `nil` for an unknown bare token.
    private static func dragPasteboardType(from token: String) -> NSPasteboard.PasteboardType? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "fileurl", "file-url", "public.file-url":
            return .fileURL
        case "tabtransfer", "tab-transfer", "com.splittabbar.tabtransfer":
            return DragOverlayRoutingPolicy.bonsplitTabTransferType
        case "sidebarreorder", "sidebar-reorder", "sidebar_tab_reorder",
            "com.cmux.sidebar-tab-reorder":
            return DragOverlayRoutingPolicy.sidebarTabReorderType
        default:
            // Allow explicit UTI strings for ad-hoc debug probes.
            guard token.contains(".") else { return nil }
            return NSPasteboard.PasteboardType(token)
        }
    }

    /// Renders one hit-tested view as `<class>@<pointer>{dragTypes=…}` for the
    /// `drag_hit_chain` probe (capping the rendered drag-type list at four).
    private static func debugDragHitViewDescriptor(_ view: NSView) -> String {
        let className = String(describing: type(of: view))
        let pointer = String(describing: Unmanaged.passUnretained(view).toOpaque())
        let types = view.registeredDraggedTypes
        let renderedTypes: String
        if types.isEmpty {
            renderedTypes = "-"
        } else {
            let raw = types.map(\.rawValue)
            renderedTypes = raw.count <= 4
                ? raw.joined(separator: ",")
                : raw.prefix(4).joined(separator: ",") + ",+\(raw.count - 4)"
        }
        return "\(className)@\(pointer){dragTypes=\(renderedTypes)}"
    }


    func setShortcut(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: set_shortcut <name> <combo|clear>"
        }

        let name = parts[0].lowercased()
        let combo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        let action: KeyboardShortcutSettings.Action?
        switch name {
        case "focus_left", "focusleft":
            action = .focusLeft
        case "focus_right", "focusright":
            action = .focusRight
        case "focus_up", "focusup":
            action = .focusUp
        case "focus_down", "focusdown":
            action = .focusDown
        case "split_right", "splitright":
            action = .splitRight
        case "split_down", "splitdown":
            action = .splitDown
        case "workspace_digits", "workspace_number", "select_workspace_by_number":
            action = .selectWorkspaceByNumber
        case "surface_digits", "surface_number", "select_surface_by_number":
            action = .selectSurfaceByNumber
        default:
            action = nil
        }

        guard let action else {
            return "ERROR: Unknown shortcut name. Supported: focus_left, focus_right, focus_up, focus_down, split_right, split_down, workspace_digits, surface_digits"
        }

        if combo.lowercased() == "clear" || combo.lowercased() == "unbound" || combo.lowercased() == "none" {
            KeyboardShortcutSettings.clearShortcut(for: action)
            return "OK"
        }

        if combo.lowercased() == "default" || combo.lowercased() == "reset" {
            KeyboardShortcutSettings.resetShortcut(for: action)
            return "OK"
        }

        guard let parsed = parseShortcutCombo(combo) else {
            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
        }

        let shortcut = StoredShortcut(
            key: parsed.storedKey,
            command: parsed.modifierFlags.contains(.command),
            shift: parsed.modifierFlags.contains(.shift),
            option: parsed.modifierFlags.contains(.option),
            control: parsed.modifierFlags.contains(.control)
        )
        if action.usesNumberedDigitMatching,
           action.normalizedRecordedShortcut(shortcut) == nil {
            return "ERROR: Numbered shortcuts must use a digit key (1-9). Example: ctrl+1"
        }

        let storedShortcut = action.normalizedRecordedShortcut(shortcut) ?? shortcut
        KeyboardShortcutSettings.setShortcut(storedShortcut, for: action)
        return "OK"
    }

    func simulateShortcut(_ args: String) -> String {
        let combo = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combo.isEmpty else {
            return "ERROR: Usage: simulate_shortcut <combo>"
        }
        guard let parsed = parseShortcutCombo(combo) else {
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
                   let windowId = AppDelegate.shared?.windowId(for: activeTabManager),
                   let window = AppDelegate.shared?.mainWindow(for: windowId) {
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
            _ = AppDelegate.shared?.activateMainWindowFromSocket()
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

    private struct RenderStatsResponse: Codable {
        let panelId: String
        let drawCount: Int
        let lastDrawTime: Double
        let metalDrawableCount: Int
        let metalLastDrawableTime: Double
        let presentCount: Int
        let lastPresentTime: Double
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
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

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode render_stats"
                return
            }

            result = "OK \(json)"
        }

        return result
    }

    private struct ParsedShortcutCombo {
        let storedKey: String
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags
        let characters: String
        let charactersIgnoringModifiers: String
    }

    private func parseShortcutCombo(_ combo: String) -> ParsedShortcutCombo? {
        let raw = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let parts = raw
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags: NSEvent.ModifierFlags = []
        var keyToken: String?

        for part in parts {
            let lower = part.lowercased()
            switch lower {
            case "cmd", "command", "super":
                flags.insert(.command)
            case "ctrl", "control":
                flags.insert(.control)
            case "opt", "option", "alt":
                flags.insert(.option)
            case "shift":
                flags.insert(.shift)
            default:
                // Treat as the key component.
                if keyToken == nil {
                    keyToken = part
                } else {
                    // Multiple non-modifier tokens is ambiguous.
                    return nil
                }
            }
        }

        guard var keyToken else { return nil }
        keyToken = keyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyToken.isEmpty else { return nil }

        // Normalize a few named keys.
        let storedKey: String
        let keyCode: UInt16
        let charactersIgnoringModifiers: String

        switch keyToken.lowercased() {
        case "left":
            storedKey = "←"
            keyCode = 123
            charactersIgnoringModifiers = storedKey
        case "right":
            storedKey = "→"
            keyCode = 124
            charactersIgnoringModifiers = storedKey
        case "down":
            storedKey = "↓"
            keyCode = 125
            charactersIgnoringModifiers = storedKey
        case "up":
            storedKey = "↑"
            keyCode = 126
            charactersIgnoringModifiers = storedKey
        case "enter", "return":
            storedKey = "\r"
            keyCode = UInt16(kVK_Return)
            charactersIgnoringModifiers = storedKey
        default:
            let key = keyToken.lowercased()
            guard let code = keyCodeForShortcutKey(key) else { return nil }
            storedKey = key
            keyCode = code

            // Replicate a common system behavior: Ctrl+letter yields a control character in
            // charactersIgnoringModifiers (e.g. Ctrl+H => backspace). This is important for
            // testing keyCode fallback matching.
            if flags.contains(.control),
               key.count == 1,
               let scalar = key.unicodeScalars.first,
               scalar.isASCII,
               scalar.value >= 97, scalar.value <= 122 { // a-z
                let upper = scalar.value - 32
                let controlValue = upper - 64 // 'A' => 1
                charactersIgnoringModifiers = String(UnicodeScalar(controlValue)!)
            } else {
                charactersIgnoringModifiers = storedKey
            }
        }

        // For our shortcut matcher, characters aren't important beyond exercising edge cases.
        let chars = charactersIgnoringModifiers

        return ParsedShortcutCombo(
            storedKey: storedKey,
            keyCode: keyCode,
            modifierFlags: flags,
            characters: chars,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )
    }

    private func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        // Matches macOS ANSI key codes for common printable keys and a few named specials.
        switch key {
        case "a": return 0   // kVK_ANSI_A
        case "s": return 1   // kVK_ANSI_S
        case "d": return 2   // kVK_ANSI_D
        case "f": return 3   // kVK_ANSI_F
        case "h": return 4   // kVK_ANSI_H
        case "g": return 5   // kVK_ANSI_G
        case "z": return 6   // kVK_ANSI_Z
        case "x": return 7   // kVK_ANSI_X
        case "c": return 8   // kVK_ANSI_C
        case "v": return 9   // kVK_ANSI_V
        case "b": return 11  // kVK_ANSI_B
        case "q": return 12  // kVK_ANSI_Q
        case "w": return 13  // kVK_ANSI_W
        case "e": return 14  // kVK_ANSI_E
        case "r": return 15  // kVK_ANSI_R
        case "y": return 16  // kVK_ANSI_Y
        case "t": return 17  // kVK_ANSI_T
        case "1": return 18  // kVK_ANSI_1
        case "2": return 19  // kVK_ANSI_2
        case "3": return 20  // kVK_ANSI_3
        case "4": return 21  // kVK_ANSI_4
        case "6": return 22  // kVK_ANSI_6
        case "5": return 23  // kVK_ANSI_5
        case "=": return 24  // kVK_ANSI_Equal
        case "9": return 25  // kVK_ANSI_9
        case "7": return 26  // kVK_ANSI_7
        case "-": return 27  // kVK_ANSI_Minus
        case "8": return 28  // kVK_ANSI_8
        case "0": return 29  // kVK_ANSI_0
        case "]": return 30  // kVK_ANSI_RightBracket
        case "o": return 31  // kVK_ANSI_O
        case "u": return 32  // kVK_ANSI_U
        case "[": return 33  // kVK_ANSI_LeftBracket
        case "i": return 34  // kVK_ANSI_I
        case "p": return 35  // kVK_ANSI_P
        case "l": return 37  // kVK_ANSI_L
        case "j": return 38  // kVK_ANSI_J
        case "'": return 39  // kVK_ANSI_Quote
        case "k": return 40  // kVK_ANSI_K
        case ";": return 41  // kVK_ANSI_Semicolon
        case "\\": return 42 // kVK_ANSI_Backslash
        case ",": return 43  // kVK_ANSI_Comma
        case "/": return 44  // kVK_ANSI_Slash
        case "n": return 45  // kVK_ANSI_N
        case "m": return 46  // kVK_ANSI_M
        case ".": return 47  // kVK_ANSI_Period
        case "`": return 50  // kVK_ANSI_Grave
        default:
            return nil
        }
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

    private struct PanelSnapshotState: Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let rgba: Data
    }

    private static let panelSnapshotLock = NSLock()

    private static var panelSnapshots: [UUID: PanelSnapshotState] = [:]

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
            Self.panelSnapshotLock.lock()
            Self.panelSnapshots.removeValue(forKey: panelId)
            Self.panelSnapshotLock.unlock()
            result = "OK"
        }

        return result
    }

    private static func makePanelSnapshot(from cgImage: CGImage) -> PanelSnapshotState? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok: Bool = data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        return PanelSnapshotState(width: width, height: height, bytesPerRow: bytesPerRow, rgba: data)
    }

    private static func countChangedPixels(previous: PanelSnapshotState, current: PanelSnapshotState) -> Int {
        // Any mismatch means we can't sensibly diff; treat as a fresh snapshot.
        guard previous.width == current.width,
              previous.height == current.height,
              previous.bytesPerRow == current.bytesPerRow else {
            return -1
        }

        let threshold = 8 // ignore tiny per-channel jitter
        var changed = 0

        previous.rgba.withUnsafeBytes { prevRaw in
            current.rgba.withUnsafeBytes { curRaw in
                guard let prev = prevRaw.bindMemory(to: UInt8.self).baseAddress,
                      let cur = curRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }

                let count = min(prevRaw.count, curRaw.count)
                var i = 0
                while i + 3 < count {
                    let dr = abs(Int(prev[i]) - Int(cur[i]))
                    let dg = abs(Int(prev[i + 1]) - Int(cur[i + 1]))
                    let db = abs(Int(prev[i + 2]) - Int(cur[i + 2]))
                    // Skip alpha channel at i+3.
                    if dr + dg + db > threshold {
                        changed += 1
                    }
                    i += 4
                }
            }
        }

        return changed
    }

    func panelSnapshot(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: panel_snapshot <panel_id|idx> [label]" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let panelArg = parts.first ?? ""
        let label = parts.count > 1 ? parts[1] : ""

        // Generate unique ID for this snapshot/screenshot
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let snapshotId = "\(timestamp)_\(shortId)"

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let filename = label.isEmpty ? "\(snapshotId).png" : "\(label)_\(snapshotId).png"
        let outputPath = outputDir.appendingPathComponent(filename)

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

            guard let current = Self.makePanelSnapshot(from: cgImage) else {
                result = "ERROR: Failed to read panel pixels"
                return
            }

            var changedPixels = -1
            Self.panelSnapshotLock.lock()
            if let previous = Self.panelSnapshots[panelId] {
                changedPixels = Self.countChangedPixels(previous: previous, current: current)
            }
            Self.panelSnapshots[panelId] = current
            Self.panelSnapshotLock.unlock()

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

    private struct LayoutDebugSelectedPanel: Codable, Sendable {
        let paneId: String
        let paneFrame: PixelRect?
        let selectedTabId: String?
        let panelId: String?
        let panelType: String?
        let inWindow: Bool?
        let hidden: Bool?
        let viewFrame: PixelRect?
        let splitViews: [LayoutDebugSplitView]?
    }

    private struct LayoutDebugSplitView: Codable, Sendable {
        let isVertical: Bool
        let dividerThickness: Double
        let bounds: PixelRect
        let frame: PixelRect?
        let arrangedSubviewFrames: [PixelRect]
        let normalizedDividerPosition: Double?
    }

    private struct LayoutDebugResponse: Codable, Sendable {
        let layout: LayoutSnapshot
        let selectedPanels: [LayoutDebugSelectedPanel]
        let mainWindowNumber: Int?
        let keyWindowNumber: Int?
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
            func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
                if view.isHidden { return true }
                var current = view.superview
                while let v = current {
                    if v.isHidden { return true }
                    current = v.superview
                }
                return false
            }

            @MainActor
            func windowFrame(for view: NSView) -> CGRect? {
                guard view.window != nil else { return nil }
                // Prefer the view's frame as laid out by its superview. Some AppKit views
                // (notably scroll views) can temporarily report stale bounds during reparenting.
                if let superview = view.superview {
                    return superview.convert(view.frame, to: nil)
                }
                return view.convert(view.bounds, to: nil)
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
                        let frame = windowFrame(for: sv).map { PixelRect(from: $0) }
                        let arranged = sv.arrangedSubviews
                        let arrangedFrames = arranged.compactMap { windowFrame(for: $0).map { PixelRect(from: $0) } }

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
                    let viewRect = windowFrame(for: tp.hostedView).map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: tp.hostedView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: tp.panelType.rawValue,
	                        inWindow: tp.surface.isViewInWindow,
	                        hidden: isHiddenOrAncestorHidden(tp.hostedView),
	                        viewFrame: viewRect,
	                        splitViews: splitViews
	                    )
	                }

                if let bp = panel as? BrowserPanel {
                    let viewRect = windowFrame(for: bp.webView).map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: bp.webView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: bp.panelType.rawValue,
	                        inWindow: bp.webView.window != nil,
	                        hidden: isHiddenOrAncestorHidden(bp.webView),
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

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode layout_debug"
                return
            }

            result = "OK \(json)"
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
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let screenshotId = "\(timestamp)_\(shortId)"

        // Determine output path
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let filename = label.isEmpty ? "\(screenshotId).png" : "\(label)_\(screenshotId).png"
        let outputPath = outputDir.appendingPathComponent(filename)

        // Capture the main window on main thread
        var captureError: String?
        v2MainSync {
            let candidateWindows = NSApp.windows.filter { window in
                window.isVisible &&
                !window.isMiniaturized &&
                window.contentView != nil &&
                !window.frame.isEmpty
            }
            let preferredWindow = [NSApp.keyWindow, NSApp.mainWindow]
                .compactMap { $0 }
                .first { candidateWindows.contains($0) }
            let window = preferredWindow ?? candidateWindows.max { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
            } ?? NSApp.mainWindow ?? NSApp.windows.first

            guard let window else {
                captureError = "No window available"
                return
            }

            guard let pngData = self.captureCompositedWindowPNGData(window)
                ?? self.captureAppKitWindowPNGData(window) else {
                captureError = "Failed to create PNG data"
                return
            }

            do {
                try pngData.write(to: outputPath)
            } catch {
                captureError = "Failed to write file: \(error.localizedDescription)"
            }
        }

        if let error = captureError {
            return "ERROR: \(error)"
        }

        // Return OK with screenshot ID and path for easy reference
        return "OK \(screenshotId) \(outputPath.path)"
    }

    private func captureCompositedWindowPNGData(_ window: NSWindow) -> Data? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func captureAppKitWindowPNGData(_ window: NSWindow) -> Data? {
        guard let contentView = window.contentView else {
            return nil
        }

        let bounds = contentView.bounds
        guard !bounds.isEmpty,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        bitmap.size = bounds.size

        contentView.displayIfNeeded()
        contentView.cacheDisplay(in: bounds, to: bitmap)

        return bitmap.representation(using: .png, properties: [:])
    }
#endif
}
