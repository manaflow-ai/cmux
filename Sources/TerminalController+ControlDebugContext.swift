import AppKit
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
/// - **v1-shared forwards** (`set_shortcut`, `read_text`, `panel_snapshot`,
///   `screenshot`, …): the v1 string bodies stay in `TerminalController.swift`
///   because the v1 `processCommand` dispatch still calls them; these
///   witnesses forward and return the raw v1 response for the coordinator to
///   parse exactly as the legacy v2 wrappers did.
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
    // These commands exist only on the v1 line protocol (no v2 method), so the
    // witnesses carry the whole app-coupled body verbatim from the former
    // `TerminalController` v1 dispatchers. They return the raw v1 response
    // string the legacy `processCommand` cases produced. `simulateShortcut`
    // (a v1-shared body that stays in `TerminalController.swift`) shares
    // `prepareWindowForSyntheticInput`, which is therefore `internal`.

    func controlDebugSimulateType(arguments: String) -> String {
        let raw = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: simulate_type <text>"
        }

        // Socket commands are line-based; allow callers to express control chars with backslash escapes.
        let text = Self.unescapeSocketText(raw)

        var result = "ERROR: No window"
        v2MainSync {
            // Like simulate_shortcut, prefer a visible window so debug automation doesn't
            // fail during key window transitions.
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else { return }
            prepareWindowForSyntheticInput(window)
            guard let fr = window.firstResponder else {
                result = "ERROR: No first responder"
                return
            }

            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = "OK"
                return
            }

            // Fall back to the responder chain insertText action. `fr` is
            // already an `NSResponder` (`window.firstResponder`), so the legacy
            // `as? NSResponder` cast was redundant; dropping it is byte-faithful
            // and clears an always-succeeds warning in this now-tracked file.
            fr.insertText(text)
            result = "OK"
        }
        return result
    }

    func controlDebugSimulateFileDrop(arguments: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let parts = arguments.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        let target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPaths = parts[1]
        let paths = rawPaths
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        var result = "ERROR: Surface not found"
        v2MainSync {
            guard let panel = resolveTerminalPanel(from: target, tabManager: tabManager) else { return }
            result = panel.hostedView.debugSimulateFileDrop(paths: paths)
                ? "OK"
                : "ERROR: Failed to simulate drop"
        }
        return result
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

    func controlDebugOverlayHitGate(arguments: String) -> String {
        let token = arguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else {
            return "ERROR: Usage: overlay_hit_gate <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
        }

        let parsedEvent = Self.parseOverlayEventType(token)
        guard parsedEvent.isKnown else {
            return "ERROR: Unknown event type '\(arguments.trimmingCharacters(in: .whitespacesAndNewlines))'"
        }
        let eventType = parsedEvent.eventType

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }

        return shouldCapture ? "true" : "false"
    }

    func controlDebugOverlayDropGate(arguments: String) -> String {
        let token = arguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasLocalDraggingSource: Bool
        switch token {
        case "", "external":
            hasLocalDraggingSource = false
        case "local":
            hasLocalDraggingSource = true
        default:
            return "ERROR: Usage: overlay_drop_gate [external|local]"
        }

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: pb.types,
                hasLocalDraggingSource: hasLocalDraggingSource
            )
        }
        return shouldCapture ? "true" : "false"
    }

    func controlDebugPortalHitGate(arguments: String) -> String {
        let token = arguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else {
            return "ERROR: Usage: portal_hit_gate <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
        }
        let parsedEvent = Self.parseOverlayEventType(token)
        guard parsedEvent.isKnown else {
            return "ERROR: Unknown event type '\(arguments.trimmingCharacters(in: .whitespacesAndNewlines))'"
        }
        let eventType = parsedEvent.eventType

        var shouldPassThrough = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }
        return shouldPassThrough ? "true" : "false"
    }

    func controlDebugSidebarOverlayGate(arguments: String) -> String {
        let token = arguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSidebarDragState: Bool
        switch token {
        case "", "active":
            hasSidebarDragState = true
        case "inactive":
            hasSidebarDragState = false
        default:
            return "ERROR: Usage: sidebar_overlay_gate [active|inactive]"
        }

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
                hasSidebarDragState: hasSidebarDragState,
                pasteboardTypes: pb.types
            )
        }
        return shouldCapture ? "true" : "false"
    }

    func controlDebugTerminalDropOverlayProbe(arguments: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let token = arguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let useDeferredPath: Bool
        switch token {
        case "", "deferred":
            useDeferredPath = true
        case "direct":
            useDeferredPath = false
        default:
            return "ERROR: Usage: terminal_drop_overlay_probe [deferred|direct]"
        }

        var result = "ERROR: No selected workspace"
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let workspace = tabManager.tabs.first(where: { $0.id == selectedId }) else {
                return
            }

            let terminalPanel = workspace.focusedTerminalPanel
                ?? orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }.first
            guard let terminalPanel else {
                result = "ERROR: No terminal panel available"
                return
            }

            let probe = terminalPanel.hostedView.debugProbeDropOverlayAnimation(
                useDeferredPath: useDeferredPath
            )
            let animated = probe.after > probe.before
            let mode = useDeferredPath ? "deferred" : "direct"
            result = String(
                format: "OK mode=%@ animated=%d before=%d after=%d bounds=%.1fx%.1f",
                mode,
                animated ? 1 : 0,
                probe.before,
                probe.after,
                probe.bounds.width,
                probe.bounds.height
            )
        }
        return result
    }

    /// Hit-tests the file-drop overlay's coordinate-to-terminal mapping.
    /// Takes normalised (0-1) x,y within the content area where (0,0) is the
    /// top-left corner and (1,1) is the bottom-right corner.  Returns the
    /// surface UUID of the terminal under that point, or "none".
    func controlDebugDropHitTest(arguments: String) -> String {
        let parts = arguments.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return "ERROR: Usage: drop_hit_test <x 0-1> <y 0-1>"
        }

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
    func controlDebugDragHitChain(arguments: String) -> String {
        let parts = arguments.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return "ERROR: Usage: drag_hit_chain <x 0-1> <y 0-1>"
        }

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

    /// Maps a lowercased overlay-gate event token to an `NSEvent.EventType`
    /// (with `none` resolving to a known `nil`), reporting whether the token was
    /// recognized.
    private static func parseOverlayEventType(_ token: String) -> (isKnown: Bool, eventType: NSEvent.EventType?) {
        switch token {
        case "leftmousedragged":
            return (true, .leftMouseDragged)
        case "rightmousedragged":
            return (true, .rightMouseDragged)
        case "othermousedragged":
            return (true, .otherMouseDragged)
        case "mousemove", "mousemoved":
            return (true, .mouseMoved)
        case "mouseentered":
            return (true, .mouseEntered)
        case "mouseexited":
            return (true, .mouseExited)
        case "flagschanged":
            return (true, .flagsChanged)
        case "cursorupdate":
            return (true, .cursorUpdate)
        case "appkitdefined":
            return (true, .appKitDefined)
        case "systemdefined":
            return (true, .systemDefined)
        case "applicationdefined":
            return (true, .applicationDefined)
        case "periodic":
            return (true, .periodic)
        case "leftmousedown":
            return (true, .leftMouseDown)
        case "leftmouseup":
            return (true, .leftMouseUp)
        case "rightmousedown":
            return (true, .rightMouseDown)
        case "rightmouseup":
            return (true, .rightMouseUp)
        case "othermousedown":
            return (true, .otherMouseDown)
        case "othermouseup":
            return (true, .otherMouseUp)
        case "scrollwheel":
            return (true, .scrollWheel)
        case "none":
            return (true, nil)
        default:
            return (false, nil)
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

    /// Unescapes the backslash escapes (`\n`, `\r`, `\t`, `\\`) the line
    /// protocol allows callers to use for control characters in
    /// `simulate_type`; unknown escapes pass through with the backslash intact.
    private static func unescapeSocketText(_ input: String) -> String {
        var out = ""
        var escaping = false
        for ch in input {
            if escaping {
                switch ch {
                case "n":
                    out.append("\n")
                case "r":
                    out.append("\r")
                case "t":
                    out.append("\t")
                case "\\":
                    out.append("\\")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping {
            out.append("\\")
        }
        return out
    }
#endif
}
