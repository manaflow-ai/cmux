import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit

extension Notification.Name {
    static let socketListenerDidStart = Notification.Name("cmux.socketListenerDidStart")
    static let terminalSurfaceDidBecomeReady = Notification.Name("cmux.terminalSurfaceDidBecomeReady")
    static let terminalSurfaceHostedViewDidMoveToWindow = Notification.Name("cmux.terminalSurfaceHostedViewDidMoveToWindow")
    static let mainWindowContextsDidChange = Notification.Name("cmux.mainWindowContextsDidChange")
    static let browserDownloadEventDidArrive = Notification.Name("cmux.browserDownloadEventDidArrive")
    static let reactGrabDidCopySelection = Notification.Name("cmux.reactGrabDidCopySelection")
}

nonisolated struct SocketLineProcessingResult: Sendable {
    let response: String?
    let authenticated: Bool
}

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    static let shared = TerminalController()

    nonisolated let remotePTYControllerAvailabilityCondition = NSCondition()
    nonisolated(unsafe) var remotePTYControllerAvailabilityGeneration: UInt64 = 0
    var tabManager: TabManager?
    /// The shared auth coordinator + browser sign-in flow, injected once via
    /// `attachAuth` at app startup (AppDelegate `configure`) before the socket
    /// listener starts. Socket auth commands read these on the main actor.
    @MainActor var authCoordinator: AuthCoordinator?
    @MainActor var browserSignInFlow: HostBrowserSignInFlow?
    // Sendable value type; injected at construction so socket auth never reaches a global.
    nonisolated let passwordStore: SocketControlPasswordStore
    // Stateless Sendable structs from CmuxControlSocket; injected at construction.
    // `transport` is internal so sibling-file extensions (CmuxEventStream) can write through it.
    nonisolated let transport: SocketTransport
    // The package-owned listener: path/bind/lock lifecycle, accept source,
    // backoff/rearm recovery, and the generation-counted state machine.
    nonisolated let socketServer: SocketControlServer
    // Per-surface dedupe for high-frequency report_* socket telemetry.
    nonisolated let socketFastPathState = SocketFastPathState()
    nonisolated let myPid = getpid()
    nonisolated static let socketListenerFailureCaptureCooldown: TimeInterval = 60
    nonisolated static let v2BrowserDownloadWaitDefaultTimeoutMs = 10_000
    nonisolated static let v2BrowserDownloadWaitMaxTimeoutMs = 120_000
    nonisolated static let socketListenerFailureCaptureLock = NSLock()
    nonisolated(unsafe) static var socketListenerFailureLastCapturedAt: [String: Date] = [:]
    struct MobileViewportReport {
        var columns: Int
        var rows: Int
        var updatedAt: Date
        /// Sticky reports come from the dedicated `mobile.terminal.viewport`
        /// RPC and live for the client's connection lifetime (cleared on
        /// disconnect or surface detach), so an idle paired device keeps its
        /// viewport border. Non-sticky reports piggyback on `terminal.input`
        /// and expire on the TTL so a client that only ever typed once does
        /// not pin the grid forever.
        var sticky: Bool = false
    }
    static let mobileViewportReportTTL: TimeInterval = 5
    var mobileViewportReportsBySurfaceID: [UUID: [String: MobileViewportReport]] = [:]
    var mobileViewportReportCleanupTimersBySurfaceID: [UUID: DispatchSourceTimer] = [:]
#if DEBUG
    nonisolated static let socketCommandDebugLogEnvironmentKey = "CMUX_DEBUG_SOCKET_COMMAND_LOG"
    nonisolated static let socketCommandSlowThresholdMs: Double = 500
#endif
    static var terminalProcessExitedMessage: String {
        String(
            localized: "socket.terminal.processExited",
            defaultValue: "The terminal session has ended; reopen it or create a new terminal session."
        )
    }

    static var terminalInputQueueFullMessage: String {
        String(
            localized: "socket.terminal.inputQueueFull",
            defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
        )
    }

    static var terminalSurfaceUnavailableMessage: String {
        String(
            localized: "socket.terminal.surfaceUnavailable",
            defaultValue: "The terminal surface is no longer available; reopen it or create a new terminal session."
        )
    }

    static var terminalProcessExitedSocketError: String {
        "ERROR: \(terminalProcessExitedMessage)"
    }

    static var terminalInputQueueFullSocketError: String {
        "ERROR: \(terminalInputQueueFullMessage)"
    }

    static var terminalSurfaceUnavailableSocketError: String {
        "ERROR: \(terminalSurfaceUnavailableMessage)"
    }

    /// Mints/resolves the stable `kind:N` handle refs handed to v2 callers
    /// (`ControlHandleKind` + `ControlHandleRegistry` live in
    /// CmuxControlSocket; main-actor isolation is provided here).
    var v2Handles = ControlHandleRegistry()

    struct V2BrowserElementRefEntry {
        let surfaceId: UUID
        let selector: String
    }

    struct V2BrowserPendingDialog {
        let type: String
        let message: String
        let defaultText: String?
        let responder: (_ accept: Bool, _ text: String?) -> Void
    }

    final class V2BrowserUndefinedSentinel {}

    static let v2BrowserEvalEnvelopeTypeKey = "__cmux_t"
    static let v2BrowserEvalEnvelopeValueKey = "__cmux_v"
    static let v2BrowserEvalEnvelopeTypeUndefined = "undefined"
    static let v2BrowserEvalEnvelopeTypeValue = "value"

    var v2BrowserNextElementOrdinal: Int = 1
    var v2BrowserElementRefs: [String: V2BrowserElementRefEntry] = [:]
    var v2BrowserFrameSelectorBySurface: [UUID: String] = [:]
    var v2BrowserInitScriptsBySurface: [UUID: [String]] = [:]
    var v2BrowserInitStylesBySurface: [UUID: [String]] = [:]
    var v2BrowserDialogQueueBySurface: [UUID: [V2BrowserPendingDialog]] = [:]
    var v2BrowserDownloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    var v2BrowserUnsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]
    let v2BrowserUndefinedSentinel = V2BrowserUndefinedSentinel()
    private var browserDownloadObserver: NSObjectProtocol?

    func cleanupSurfaceState(surfaceIds: [UUID]) {
        for surfaceId in Set(surfaceIds) {
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            v2BrowserInitScriptsBySurface.removeValue(forKey: surfaceId)
            v2BrowserInitStylesBySurface.removeValue(forKey: surfaceId)
            v2BrowserDialogQueueBySurface.removeValue(forKey: surfaceId)
            v2BrowserDownloadEventsBySurface.removeValue(forKey: surfaceId)
            v2BrowserUnsupportedNetworkRequestsBySurface.removeValue(forKey: surfaceId)
            v2BrowserElementRefs = v2BrowserElementRefs.filter { $0.value.surfaceId != surfaceId }

            v2Handles.removeRef(kind: .surface, uuid: surfaceId)
        }
    }

    /// Bridges the package server's event closures back to the controller.
    /// Assigned exactly once during `init`, before the listener can start, and
    /// read-only afterward; the controller is an app-lifetime singleton.
    final class ServerEventTarget: @unchecked Sendable {
        weak var controller: TerminalController?
    }

    private init(
        passwordStore: SocketControlPasswordStore = SocketControlPasswordStore(),
        transport: SocketTransport = SocketTransport(),
        listenerPolicy: SocketListenerPolicy = SocketListenerPolicy()
    ) {
        self.passwordStore = passwordStore
        self.transport = transport
        let serverEventTarget = ServerEventTarget()
        self.socketServer = SocketControlServer(
            transport: transport,
            listenerPolicy: listenerPolicy,
            events: Self.makeSocketServerEvents(target: serverEventTarget)
        )
        serverEventTarget.controller = self
        browserDownloadObserver = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let surfaceId = note.userInfo?["surfaceId"] as? UUID,
                  let event = note.userInfo?["event"] as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var queue = self.v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                queue.append(event)
                self.v2BrowserDownloadEventsBySurface[surfaceId] = queue
            }
        }
    }

    nonisolated func currentSocketPathForRemoteRestore() -> String? {
        socketServer.currentSocketPathForRemoteRestore()
    }

    @discardableResult
    nonisolated func reserveStartupSocketPath(_ path: String) -> String {
        socketServer.reserveStartupSocketPath(path)
    }

    nonisolated func activeSocketPath(preferredPath: String) -> String {
        socketServer.activeSocketPath(preferredPath: preferredPath)
    }

    /// Update which window's TabManager receives socket commands.
    /// This is used when the user switches between multiple terminal windows.
    func setActiveTabManager(_ tabManager: TabManager?) {
        if let tabManager {
            AppDelegate.shared?.ensureMobileWorkspaceListObserver(for: tabManager)
        }
        self.tabManager = tabManager
    }

    func activeTabManagerForCallerNotification() -> TabManager? { tabManager }

    // MARK: - Process Ancestry Check

#if DEBUG
    // MARK: - V2 Debug / Test-only Methods

    func v2DebugShortcutSet(params: [String: Any]) -> V2CallResult {
        guard let name = v2String(params, "name"),
              let combo = v2String(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing name/combo", data: nil)
        }
        let resp = setShortcut("\(name) \(combo)")
        return resp == "OK"
            ? .ok([:])
            : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugShortcutSimulate(params: [String: Any]) -> V2CallResult {
        guard let combo = v2String(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing combo", data: nil)
        }
        let resp = simulateShortcut(combo)
        return resp == "OK"
            ? .ok([:])
            : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugType(params: [String: Any]) -> V2CallResult {
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "No window", data: nil)
        v2MainSync {
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else {
                result = .err(code: "not_found", message: "No window", data: nil)
                return
            }
            if socketCommandAllowsInAppFocusMutations() {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            guard let fr = window.firstResponder else {
                result = .err(code: "not_found", message: "No first responder", data: nil)
                return
            }
            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = .ok([:])
                return
            }
            (fr as? NSResponder)?.insertText(text)
            result = .ok([:])
        }
        return result
    }


    func v2DebugActivateApp() -> V2CallResult {
        let resp = activateApp()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugToggleCommandPalette(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        v2MainSync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: ["window_id": requestedWindowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteToggleRequested, object: targetWindow)
        }
        return result
    }

    func v2DebugOpenCommandPaletteRenameTabInput(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        v2MainSync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameTabRequested, object: targetWindow)
        }
        return result
    }

    func v2DebugCommandPaletteVisible(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visible = false
        v2MainSync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible
        ])
    }

    func v2DebugCommandPaletteSelection(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visible = false
        var selectedIndex = 0
        v2MainSync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
            selectedIndex = AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowId) ?? 0
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible,
            "selected_index": max(0, selectedIndex)
        ])
    }

    func v2DebugCommandPaletteResults(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let requestedLimit = params["limit"] as? Int
        let limit = max(1, min(100, requestedLimit ?? 20))

        var visible = false
        var selectedIndex = 0
        var snapshot = CommandPaletteDebugSnapshot.empty

        v2MainSync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
            selectedIndex = AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowId) ?? 0
            snapshot = AppDelegate.shared?.commandPaletteSnapshot(windowId: windowId) ?? .empty
        }

        let rows = Array(snapshot.results.prefix(limit)).map { row in
            [
                "command_id": row.commandId,
                "title": row.title,
                "shortcut_hint": v2OrNull(row.shortcutHint),
                "trailing_label": v2OrNull(row.trailingLabel),
                "score": row.score
            ] as [String: Any]
        }

        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible,
            "selected_index": max(0, selectedIndex),
            "query": snapshot.query,
            "mode": snapshot.mode,
            "results": rows
        ])
    }

    func v2DebugCommandPaletteRenameInputInteraction(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        v2MainSync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameInputInteractionRequested, object: targetWindow)
        }
        return result
    }

    func v2DebugCommandPaletteRenameInputDeleteBackward(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        v2MainSync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameInputDeleteBackwardRequested, object: targetWindow)
        }
        return result
    }

    func v2DebugCommandPaletteRenameInputSelection(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }

        var result: V2CallResult = .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "focused": false,
            "selection_location": 0,
            "selection_length": 0,
            "text_length": 0
        ])

        v2MainSync {
            guard let window = AppDelegate.shared?.mainWindow(for: windowId) else {
                result = .err(
                    code: "not_found",
                    message: "Window not found",
                    data: ["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)]
                )
                return
            }
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
                return
            }
            let selectedRange = editor.selectedRange()
            let textLength = (editor.string as NSString).length
            result = .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "focused": true,
                "selection_location": max(0, selectedRange.location),
                "selection_length": max(0, selectedRange.length),
                "text_length": max(0, textLength)
            ])
        }

        return result
    }

    func v2DebugCommandPaletteRenameInputSelectAll(params: [String: Any]) -> V2CallResult {
        if let rawEnabled = params["enabled"] {
            guard let enabled = rawEnabled as? Bool else {
                return .err(
                    code: "invalid_params",
                    message: "enabled must be a bool",
                    data: ["enabled": rawEnabled]
                )
            }
            v2MainSync {
                UserDefaults.standard.set(
                    enabled,
                    forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey
                )
            }
        }

        var enabled = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
        v2MainSync {
            enabled = CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled()
        }

        return .ok([
            "enabled": enabled
        ])
    }

    func v2DebugBrowserAddressBarFocused(params: [String: Any]) -> V2CallResult {
        let requestedSurfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "panel_id")
        var focusedSurfaceId: UUID?
        v2MainSync {
            focusedSurfaceId = AppDelegate.shared?.focusedBrowserAddressBarPanelId()
        }

        var payload: [String: Any] = [
            "focused_surface_id": v2OrNull(focusedSurfaceId?.uuidString),
            "focused_surface_ref": v2Ref(kind: .surface, uuid: focusedSurfaceId),
            "focused_panel_id": v2OrNull(focusedSurfaceId?.uuidString),
            "focused_panel_ref": v2Ref(kind: .surface, uuid: focusedSurfaceId),
            "focused": focusedSurfaceId != nil
        ]

        if let requestedSurfaceId {
            payload["surface_id"] = requestedSurfaceId.uuidString
            payload["surface_ref"] = v2Ref(kind: .surface, uuid: requestedSurfaceId)
            payload["panel_id"] = requestedSurfaceId.uuidString
            payload["panel_ref"] = v2Ref(kind: .surface, uuid: requestedSurfaceId)
            payload["focused"] = (focusedSurfaceId == requestedSurfaceId)
        }

        return .ok(payload)
    }

    func v2DebugBrowserFavicon(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
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
    }


    func v2DebugSidebarVisible(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visibility: Bool?
        v2MainSync {
            visibility = AppDelegate.shared?.sidebarVisibility(windowId: windowId)
        }
        guard let visible = visibility else {
            return .err(
                code: "not_found",
                message: "Window not found",
                data: ["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)]
            )
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible
        ])
    }

    func v2DebugIsTerminalFocused(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = isTerminalFocused(surfaceId)
        if resp.hasPrefix("ERROR") {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        return .ok(["focused": resp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"])
    }


    func v2DebugReadTerminalText(params: [String: Any]) -> V2CallResult {
        let surfaceArg = v2String(params, "surface_id") ?? ""
        let resp = readTerminalText(surfaceArg)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let b64 = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .ok(["base64": b64])
    }

    func v2DebugRenderStats(params: [String: Any]) -> V2CallResult {
        let surfaceArg = v2String(params, "surface_id") ?? ""
        let resp = renderStats(surfaceArg)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .err(code: "internal_error", message: "render_stats JSON decode failed", data: ["payload": String(jsonStr.prefix(200))])
        }
        return .ok(["stats": obj])
    }

    func v2DebugLayout() -> V2CallResult {
        let resp = layoutDebug()
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .err(code: "internal_error", message: "layout_debug JSON decode failed", data: ["payload": String(jsonStr.prefix(200))])
        }
        return .ok(["layout": obj])
    }

    func v2DebugPortalStats() -> V2CallResult {
        let payload: [String: Any] = v2MainSync {
            TerminalWindowPortalRegistry.debugPortalStats()
        }
        return .ok(payload)
    }

    func v2DebugBonsplitUnderflowCount() -> V2CallResult {
        let resp = bonsplitUnderflowCount()
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    func v2DebugResetBonsplitUnderflowCount() -> V2CallResult {
        let resp = resetBonsplitUnderflowCount()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugEmptyPanelCount() -> V2CallResult {
        let resp = emptyPanelCount()
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    func v2DebugResetEmptyPanelCount() -> V2CallResult {
        let resp = resetEmptyPanelCount()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugFocusNotification(params: [String: Any]) -> V2CallResult {
        guard let wsId = v2String(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let surfaceId = v2String(params, "surface_id")
        let args = surfaceId != nil ? "\(wsId) \(surfaceId!)" : wsId
        let resp = focusFromNotification(args)
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugFlashCount(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = flashCount(surfaceId)
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    func v2DebugResetFlashCounts() -> V2CallResult {
        let resp = resetFlashCounts()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugPanelSnapshot(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let label = v2String(params, "label") ?? ""
        let args = label.isEmpty ? surfaceId : "\(surfaceId) \(label)"
        let resp = panelSnapshot(args)
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 4).map(String.init)
        guard parts.count == 5 else {
            return .err(code: "internal_error", message: "panel_snapshot parse failed", data: ["payload": payload])
        }
        return .ok([
            "surface_id": parts[0],
            "changed_pixels": Int(parts[1]) ?? -1,
            "width": Int(parts[2]) ?? 0,
            "height": Int(parts[3]) ?? 0,
            "path": parts[4]
        ])
    }

    func v2DebugPanelSnapshotReset(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = panelSnapshotReset(surfaceId)
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugScreenshot(params: [String: Any]) -> V2CallResult {
        let label = v2String(params, "label") ?? ""
        let resp = captureScreenshot(label)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return .err(code: "internal_error", message: "screenshot parse failed", data: ["payload": payload])
        }
        return .ok([
            "screenshot_id": parts[0],
            "path": parts[1]
        ])
    }
#endif

    deinit {
        if let browserDownloadObserver {
            NotificationCenter.default.removeObserver(browserDownloadObserver)
        }
        stop()
    }
}
