import AppKit
import CmuxBrowser
import CmuxCEF
import CmuxCEFBrowser
import Foundation
import os

/// The `engine` parameter of browser-creating socket methods
/// (`browser.open_split`, `browser.tab.new`) and the `engine` field their
/// results report.
///
/// An explicit engine the app cannot open is refused with the reason, never
/// silently replaced by WebKit, so a script that asked for Chromium knows it
/// did not get it (engine decision E2, same as cmux Next).
extension TerminalController {
    /// The engine named by the `engine` parameter, nil when absent.
    nonisolated func v2BrowserRequestedEngine(
        _ params: [String: Any]
    ) -> (engine: BrowserEngineKind?, error: V2CallResult?) {
        guard v2HasNonNullParam(params, "engine") else { return (nil, nil) }
        guard let raw = params["engine"] as? String,
              let engine = BrowserEngineKind(requestValue: raw) else {
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.engine.error.invalid",
                    defaultValue: "Choose WebKit or Chromium for the browser engine."
                ),
                data: ["engine": params["engine"].map { "\($0)" } ?? NSNull()]
            ))
        }
        return (engine, nil)
    }

    /// Why a WebKit panel is not on the engine it wanted (`CMUX_BROWSER_ENGINE`,
    /// an inherited engine or `browser.engine` named one that could not open,
    /// or its Chromium runtime failed to start); nil otherwise, including for
    /// an explicit `--engine webkit`.
    @MainActor
    func v2BrowserEngineFallbackReason(_ panel: BrowserPanel) -> BrowserEngineUnavailableReason? {
        // The panel records why it is WebKit although Chromium was wanted
        // (at creation or after a start failure).
        panel.activeEngineKind == .webkit ? panel.engineFallbackReason : nil
    }

    /// The `engine` (and, after a fallback, `engine_fallback_reason`) fields
    /// browser results carry, so a script can tell which engine it drives.
    @MainActor
    func v2BrowserEngineFields(
        _ panel: BrowserPanel,
        requested: BrowserEngineKind? = nil,
        runtime: BrowserEngineRuntime = .shared
    ) -> [String: Any] {
        var fields: [String: Any] = ["engine": panel.activeEngineKind.rawValue]
        if let requested, requested != panel.activeEngineKind {
            // An explicit engine that resolved but then could not create the
            // page (its runtime failed to start) renders WebKit: say why,
            // never report the requested engine.
            let reason = panel.engineFallbackReason
                ?? runtime.availability(for: requested).unavailableReason
                ?? .startFailed("page creation failed")
            fields["engine_fallback_reason"] = reason.code
            if let detail = reason.detail {
                fields["engine_fallback_detail"] = detail
            }
        } else if let reason = v2BrowserEngineFallbackReason(panel) {
            fields["engine_fallback_reason"] = reason.code
        }
        return fields
    }

    /// The panel's non-WebKit engine page, or nil for a WebKit panel. The
    /// engine is fixed at panel creation, so a WebKit panel answers without a
    /// main-thread hop and its automation paths cost nothing extra.
    nonisolated func v2EnginePage(_ panel: BrowserPanel) -> (any BrowserPage)? {
        guard panel.engineKind != .webkit else { return nil }
        return v2MainSync { panel.automationEnginePage }
    }

    /// The refusal for scripting, input, cookies or screenshots on a page an
    /// agent may not drive: a Chromium internal page (settings, passwords,
    /// extensions, DevTools) the person opened in the panel, or a page an
    /// enabled third-party extension of the panel's profile can reach (a
    /// password manager's autofill could hand the agent a password;
    /// `BrowserExtensionAgentAccess`). Nil when the agent may drive it, and
    /// always for WebKit panels.
    @MainActor
    func v2EngineAgentRefusal(_ panel: BrowserPanel, surfaceId: UUID) -> V2CallResult? {
        // A page whose renderer exited cannot run scripts or take input until
        // it reloads: fail at once with the exit, not after a script timeout.
        // Navigations (reload, navigate) do not pass through here and recover it.
        if let exit = panel.automationEnginePage?.state.processExit {
            var data: [String: Any] = [
                "surface_id": surfaceId.uuidString,
                "exit": String(describing: exit.kind),
            ]
            if let status = exit.status {
                data["status"] = Int(status)
            }
            return .err(
                code: "page_crashed",
                message: String(
                    localized: "browser.automation.error.pageCrashed",
                    defaultValue: "The browser page crashed. Reload it with cmux browser reload, then retry."
                ),
                data: data
            )
        }
        guard panel.agentMayDriveCurrentPage else {
            return .err(
                code: "agent_refused",
                message: String(
                    localized: "browser.automation.error.internalPageRefused",
                    defaultValue: "Agents can't script or send input to this browser's internal pages"
                ),
                data: [
                    "surface_id": surfaceId.uuidString,
                    "url": panel.currentURL?.absoluteString ?? "",
                ]
            )
        }
        return v2ExtensionAgentRefusal(panel, surfaceId: surfaceId)
    }

    /// The refusal for a page that enabled extensions of the panel's profile can reach.
    @MainActor
    private func v2ExtensionAgentRefusal(_ panel: BrowserPanel, surfaceId: UUID) -> V2CallResult? {
        let blockers = panel.extensionAutomationBlockers()
        guard !blockers.isEmpty else { return nil }
        return .err(
            code: "agent_refused",
            message: String(
                localized: "browser.automation.error.extensionAccessRefused",
                defaultValue: "Agents can't drive a page that an enabled extension can read. Use a browser profile without extensions for agent work, or turn the extension off."
            ),
            data: [
                "surface_id": surfaceId.uuidString,
                "url": panel.currentURL?.absoluteString ?? "",
                "reason": "extension_host_access",
                "extensions": blockers.map(\.name),
            ]
        )
    }

    /// `v2EngineAgentRefusal` from the socket worker.
    nonisolated func v2EngineAgentRefusalOnWorker(_ panel: BrowserPanel, surfaceId: UUID) -> V2CallResult? {
        v2MainSync { v2EngineAgentRefusal(panel, surfaceId: surfaceId) }
    }

    /// Runs `source` at the start of every document the engine page loads
    /// from now on (`Page.addScriptToEvaluateOnNewDocument`). Nil on success,
    /// else the socket error.
    nonisolated func v2EngineAddScriptOnNewDocument(
        _ page: any BrowserPage,
        source: String,
        surfaceId: UUID
    ) -> V2CallResult? {
        let outcome: Result<Void, any Error>? = v2AwaitEnginePage(timeout: 5.0) {
            do {
                try await BrowserPageAutomation(page: page).addScriptOnNewDocument(source)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case nil: return v2EngineAutomationTimeout(surfaceId: surfaceId)
        case .failure(let error): return v2EngineAutomationError(error, surfaceId: surfaceId)
        case .success: return nil
        }
    }

    /// Engine surfaces whose telemetry hooks are registered for new documents.
    private static let v2EngineTelemetrySurfaces = OSAllocatedUnfairLock(initialState: Set<UUID>())

    /// True the first time a surface asks, so the hooks are registered once.
    nonisolated func v2EngineClaimTelemetryHooks(surfaceId: UUID) -> Bool {
        Self.v2EngineTelemetrySurfaces.withLock { $0.insert(surfaceId).inserted }
    }

    /// Modifier keys automation holds down per engine surface (DevTools key
    /// events carry no keyboard state of their own).
    @MainActor private static var v2EngineHeldModifiers: [UUID: BrowserAutomationHeldModifiers] = [:]

    /// Records one automation key action on an engine surface and returns the
    /// modifiers to send with it, so `keydown Shift` then `press a` types `A`.
    @MainActor
    func v2EngineKeyModifiers(
        surfaceId: UUID,
        event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) -> BrowserKeyboardNativeModifiers {
        var state = Self.v2EngineHeldModifiers[surfaceId] ?? BrowserAutomationHeldModifiers()
        let modifiers = state.record(event, action: action)
        Self.v2EngineHeldModifiers[surfaceId] = state.held.isEmpty ? nil : state
        return modifiers
    }

    /// Runs one engine-page operation on the main actor and waits for it on
    /// the socket worker, at most `timeout` seconds. Nil when it did not finish
    /// in time (the operation is then cancelled).
    nonisolated func v2AwaitEnginePage<T>(
        timeout: TimeInterval,
        _ operation: @escaping @MainActor () async -> T
    ) -> T? {
        var task: Task<Void, Never>?
        let outcome: T? = v2AwaitCallback(timeout: max(0.01, timeout)) { finish in
            task = Task { @MainActor in
                finish(await operation())
            }
        }
        if outcome == nil {
            task?.cancel()
        }
        return outcome
    }

    /// The socket error text for an engine-page automation failure.
    nonisolated static func v2EngineAutomationMessage(_ error: any Error) -> String {
        if let error = error as? BrowserAutomationPageError {
            return error.message
        }
        return error.localizedDescription
    }

    /// The socket error for an engine-page automation failure.
    nonisolated func v2EngineAutomationError(_ error: any Error, surfaceId: UUID) -> V2CallResult {
        let code: String
        let data: [String: Any] = ["surface_id": surfaceId.uuidString]
        switch error as? BrowserAutomationPageError {
        case .javaScript: code = "js_error"
        case .pageUnavailable(let reason):
            return v2EnginePageUnavailable(reason, surfaceId: surfaceId)
        case .unsupported: code = "not_supported"
        default: code = "internal_error"
        }
        return .err(code: code, message: Self.v2EngineAutomationMessage(error), data: data)
    }

    /// The one error every browser command returns when a Chromium surface's
    /// page cannot run: `engine_unavailable`, with the engine's reason
    /// (`notBundled`, `startFailed` with its detail, `shutDown`) when it has
    /// one, or `pageClosed` when only this page is gone.
    nonisolated func v2EnginePageUnavailable(
        _ reason: BrowserEngineUnavailableReason?,
        surfaceId: UUID?
    ) -> V2CallResult {
        var data: [String: Any] = [
            "surface_id": surfaceId.map { $0.uuidString as Any } ?? NSNull(),
            "engine": BrowserEngineKind.chromium.rawValue,
            "reason": reason?.code ?? "pageClosed",
        ]
        if let detail = reason?.detail {
            data["detail"] = detail
        }
        return .err(
            code: "engine_unavailable",
            message: BrowserAutomationPageError.pageUnavailable(reason).message,
            data: data
        )
    }

    /// Thread-local side channel: a script-backed command on an engine page
    /// records here that the page could not run, so the socket-worker
    /// dispatcher can answer `engine_unavailable` instead of the command's
    /// own `js_error` wrapping. Each command runs synchronously on one
    /// worker thread.
    private static let v2EngineUnavailableThreadKey = "cmux.automation.engineUnavailable"

    nonisolated func v2RecordEnginePageUnavailable(_ reason: BrowserEngineUnavailableReason?, surfaceId: UUID?) {
        v2RecordEngineCommandError(v2EnginePageUnavailable(reason, surfaceId: surfaceId))
    }

    /// Records the error a failed command on an engine page answers with
    /// (engine_unavailable, page_crashed, agent_refused), replacing the
    /// command's own wrapping of the failure.
    nonisolated func v2RecordEngineCommandError(_ error: V2CallResult) {
        Thread.current.threadDictionary[Self.v2EngineUnavailableThreadKey] = V2EngineUnavailableRecord(error: error)
    }

    /// Rewrites a failed command's error to `engine_unavailable` when its
    /// engine page could not run during the command; clears the record.
    nonisolated func v2ApplyEnginePageUnavailable(_ result: V2CallResult) -> V2CallResult {
        let dictionary = Thread.current.threadDictionary
        guard let record = dictionary[Self.v2EngineUnavailableThreadKey] as? V2EngineUnavailableRecord else {
            return result
        }
        dictionary.removeObject(forKey: Self.v2EngineUnavailableThreadKey)
        guard case .err = result else { return result }
        return record.error
    }

    /// Clears a stale record before a command runs.
    nonisolated func v2ClearEnginePageUnavailable() {
        Thread.current.threadDictionary.removeObject(forKey: Self.v2EngineUnavailableThreadKey)
    }

    /// The error for an engine-page operation that did not finish in time.
    nonisolated func v2EngineAutomationTimeout(surfaceId: UUID) -> V2CallResult {
        .err(
            code: "timeout",
            message: String(
                localized: "browser.automation.error.engineTimedOut",
                defaultValue: "Timed out waiting for the browser engine"
            ),
            data: ["surface_id": surfaceId.uuidString]
        )
    }

    /// The refusal for an explicitly requested engine that cannot open, or
    /// nil when the request can be honored.
    ///
    /// The app's engine runtime decides: Chromium is available once its
    /// provider is registered (the runtime is bundled and started).
    @MainActor
    func v2BrowserEngineRefusal(
        _ requested: BrowserEngineKind?,
        runtime: BrowserEngineRuntime = .shared
    ) -> V2CallResult? {
        guard let requested,
              case .refuse(let engine, let reason) = runtime.resolve(requested: requested) else {
            return nil
        }
        var data: [String: Any] = ["engine": engine.rawValue, "reason": reason.code]
        if let detail = reason.detail {
            data["detail"] = detail
        }
        return .err(
            code: "engine_unavailable",
            message: String(
                localized: "cli.browser.engine.error.chromiumUnavailable",
                defaultValue: "The Chromium browser engine is not available"
            ) + " (\(reason.code))",
            data: data
        )
    }

    /// Dock browsers open with WebKit only; an explicit other engine is
    /// refused there.
    nonisolated func v2BrowserEngineUnsupportedInDock(_ engine: BrowserEngineKind) -> V2CallResult {
        .err(
            code: "not_supported",
            message: String(
                localized: "cli.browser.engine.error.dockUnsupported",
                defaultValue: "Dock browsers use WebKit; open the page in a workspace pane to use another engine"
            ),
            data: ["engine": engine.rawValue]
        )
    }
}

/// An engine page that could not run during the current socket command.
private final class V2EngineUnavailableRecord {
    let error: TerminalController.V2CallResult

    init(error: TerminalController.V2CallResult) {
        self.error = error
    }
}

// MARK: - Bringing an engine page up for automation

/// A non-WebKit page automation can start on demand: Chromium creates its
/// browser lazily (a never-shown pane) and Memory Saver closes it while the
/// pane is hidden; neither takes DevTools commands until it is live again.
@MainActor
protocol BrowserEnginePageAutomationStarting: AnyObject {
    /// The page can take DevTools commands now.
    var isLiveForAutomation: Bool { get }
    /// Creates the page's engine content when nothing else will (idempotent).
    func startForAutomation()
}

extension CEFBrowserPage: BrowserEnginePageAutomationStarting {
    var isLiveForAutomation: Bool {
        browser.browserID != nil && !browser.isClosed && !browser.isContentReleased
    }

    func startForAutomation() {
        guard !browser.isClosed, !browser.isContentReleased else { return }
        browser.createNow()
    }
}

/// Waiters for an engine page to become live, woken by the panel's page
/// events (the page creates its browser, then reports its load state).
@MainActor
enum BrowserEnginePageAutomationReadiness {
    private static var waiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    /// A page event: wakes everyone waiting on `page`; each re-checks.
    static func pageEvent(_ page: any BrowserPage) {
        wake(ObjectIdentifier(page))
    }

    static func wake(_ key: ObjectIdentifier) {
        guard let woken = waiters.removeValue(forKey: key) else { return }
        for waiter in woken { waiter.resume() }
    }

    /// Suspends until the next wake for `key`, or until cancelled.
    static func nextWake(_ key: ObjectIdentifier) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { return continuation.resume() }
                waiters[key, default: []].append(continuation)
            }
        } onCancel: {
            Task { @MainActor in wake(key) }
        }
    }
}

extension BrowserPanel {
    /// Whether an engine page has keyboard focus (`is_webview_focused`): the
    /// first responder is inside its content view, or, for a page drawn in
    /// its own child window over the pane (Chromium), that window is key.
    static func enginePageHasKeyboardFocus(_ page: any BrowserPage) -> Bool {
        let view = page.contentView
        guard let window = view.window else { return false }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) { return true }
        guard page.presentation == .childWindow else { return false }
        let paneFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
#if DEBUG
        let children = (window.childWindows ?? []).map { child in
            "\(type(of: child)) key=\(child.isKeyWindow ? 1 : 0) frame=\(child.frame) fr=\(child.firstResponder.map { "\(type(of: $0))" } ?? "nil")"
        }
        cmuxDebugLog(
            "browser.engine.focusProbe pane=\(paneFrame) appActive=\(NSApp.isActive ? 1 : 0) " +
            "key=\(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "nil") children=\(children)"
        )
#endif
        guard let key = NSApp.keyWindow, key.parent === window else { return false }
        // The key child window over this pane, not another pane's page.
        let overlap = key.frame.intersection(paneFrame)
        guard !overlap.isNull else { return false }
        let smaller = min(key.frame.width * key.frame.height, paneFrame.width * paneFrame.height)
        return smaller > 0 && overlap.width * overlap.height >= smaller / 2
    }

    /// Restores a page Memory Saver released and creates one that was never
    /// created, so an automation command can drive it.
    /// - Returns: The page to wait for, or nil when it is already live (or
    ///   has no engine page that starts on demand).
    func startEnginePageForAutomation() -> (any BrowserPage & BrowserEnginePageAutomationStarting)? {
        guard let page = enginePage as? any BrowserPage & BrowserEnginePageAutomationStarting,
              !page.isLiveForAutomation,
              !isEngineUnavailableForAutomation(page) else { return nil }
        // An agent needs the page now: restore even when the person restores
        // released pages by hand, as for a discarded WebKit tab.
        restoreDiscardedWebViewIfNeeded(reason: "automation_command", trigger: .explicitRequest)
        if !page.isLiveForAutomation { page.startForAutomation() }
        return page.isLiveForAutomation ? nil : page
    }

    /// Waits until `page` is live, or `timeout` passes.
    /// - Returns: Whether the page is live.
    func waitForEnginePageAutomationReadiness(
        _ page: any BrowserPage & BrowserEnginePageAutomationStarting,
        timeout: Duration
    ) async -> Bool {
        let key = ObjectIdentifier(page)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        // The command's readiness deadline, not a settle delay: it wakes the
        // waiter below one last time.
        let timer = Task { @MainActor in
            try? await clock.sleep(until: deadline)
            BrowserEnginePageAutomationReadiness.wake(key)
        }
        defer { timer.cancel() }
        while !page.isLiveForAutomation {
            // An engine that failed to start reports at once, not at the deadline.
            if Task.isCancelled || clock.now >= deadline || isEngineUnavailableForAutomation(page) { return false }
            await BrowserEnginePageAutomationReadiness.nextWake(key)
        }
        return true
    }

    private func isEngineUnavailableForAutomation(_ page: any BrowserPage) -> Bool {
        engineRuntime.availability(for: page.engineKind).unavailableReason != nil
    }
}

extension TerminalController {
    /// Socket methods that load the page themselves, so they skip the
    /// automation start below.
    nonisolated static let v2EngineSelfLoadingMethods: Set<String> = [
        "browser.navigate", "browser.reload",
    ]

    /// Before a browser automation command: when its surface is a Chromium
    /// page Memory Saver released, or one that was never created, restore or
    /// create it and wait (socket worker, bounded) until it takes DevTools
    /// commands, as WebKit restores a discarded tab for automation. A page
    /// that does not come up leaves the command to report the engine's error.
    nonisolated func v2StartEnginePageForAutomation(method: String, params: [String: Any]) {
        guard !Self.v2EngineSelfLoadingMethods.contains(method) else { return }
        let pending: (BrowserPanel, any BrowserPage & BrowserEnginePageAutomationStarting)? = v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params),
                  let context = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager).context,
                  context.browserPanel.engineKind != .webkit,
                  let page = context.browserPanel.startEnginePageForAutomation() else { return nil }
            return (context.browserPanel, page)
        }
        guard let (panel, page) = pending else { return }
#if DEBUG
        cmuxDebugLog("browser.automation.engine.start method=\(method) panel=\(panel.id.uuidString.prefix(5))")
#endif
        _ = v2AwaitEnginePage(timeout: 10) {
            await panel.waitForEnginePageAutomationReadiness(page, timeout: .seconds(10))
        }
    }
}
