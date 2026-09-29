import CmuxBrowser
import CmuxControlSocket
import Foundation

/// Process-wide REPL state: live sessions and the bundled runtime.
final class BrowserReplHost: @unchecked Sendable {
    static let shared = BrowserReplHost()

    let registry = BrowserReplSessionRegistry()
    private let lock = NSLock()
    private var cachedBundle: BrowserReplRuntimeBundle?

    /// The runtime bundled in the app. `CMUX_BROWSER_REPL_RUNTIME_DIR` points a
    /// development build at a source checkout instead, re-read per session.
    var bundle: BrowserReplRuntimeBundle {
        if let override = ProcessInfo.processInfo.environment["CMUX_BROWSER_REPL_RUNTIME_DIR"], !override.isEmpty {
            return BrowserReplRuntimeBundle.load(from: URL(fileURLWithPath: override, isDirectory: true))
        }
        return lock.withLock {
            if let cachedBundle { return cachedBundle }
            let loaded = Bundle.main.resourceURL
                .map { $0.appendingPathComponent("browser-repl", isDirectory: true) }
                .map(BrowserReplRuntimeBundle.load(from:))
                ?? BrowserReplRuntimeBundle(replScripts: [], agentScripts: [])
            cachedBundle = loaded
            return loaded
        }
    }
}

/// Socket methods `browser.repl.eval`, `browser.repl.reset` and `browser.repl.list`.
///
/// Evaluations await the REPL's JavaScriptCore thread and the main-actor
/// driver without parking a socket worker thread. These methods execute
/// scripts that drive local browser tabs and read and write files under the
/// caller's directory, so they are not allowlisted for remote relays.
extension TerminalController {
    nonisolated static func isBrowserReplMethod(_ method: String) -> Bool {
        method == "browser.repl.eval" || method == "browser.repl.reset" || method == "browser.repl.list"
    }

    nonisolated func v2BrowserReplResponse(request: ControlRequest) async -> String {
        let result: V2CallResult
        switch request.method {
        case "browser.repl.eval":
            result = await v2BrowserReplEval(request: request)
        case "browser.repl.reset":
            let session = request.params["session"]?.foundationObject as? String ?? ""
            guard !session.isEmpty else {
                result = .err(code: "invalid_params", message: Self.browserReplMissingSessionMessage, data: nil)
                break
            }
            let existed = BrowserReplHost.shared.registry.reset(named: session)
            result = .ok(["session": session, "existed": existed])
        default:
            let sessions = BrowserReplHost.shared.registry.list().map { entry -> [String: Any] in
                ["session": entry.id, "cwd": entry.cwd, "idle_seconds": entry.idleSeconds]
            }
            result = .ok(["sessions": sessions])
        }
        return v2Result(id: request.id?.foundationObject, result)
    }

    private nonisolated static var browserReplMissingSessionMessage: String {
        String(localized: "cli.browser.repl.error.sessionRequired", defaultValue: "A session name is required")
    }

    private nonisolated func v2BrowserReplEval(request: ControlRequest) async -> V2CallResult {
        let params = request.params.mapValues(\.foundationObject)
        guard let code = params["code"] as? String else {
            return .err(
                code: "invalid_params",
                message: String(localized: "cli.browser.repl.error.codeRequired", defaultValue: "No code to evaluate"),
                data: nil
            )
        }
        let dialect = (params["dialect"] as? String) ?? "aside"
        guard dialect == "aside" || dialect == "chatgpt" else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.repl.error.dialect",
                    defaultValue: "Unknown dialect; use aside or chatgpt"
                ),
                data: nil
            )
        }
        let cwd = (params["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-repl").path
        let timeoutMilliseconds = (params["timeout_ms"] as? NSNumber)?.intValue ?? 120_000
        let named = (params["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sessionID = named ?? "oneshot-\(UUID().uuidString)"

        guard let workspaceID = await v2BrowserReplWorkspaceID(request: request) else {
            return .err(
                code: "not_found",
                message: String(localized: "cli.browser.repl.error.workspace", defaultValue: "No workspace to bind the REPL session to"),
                data: nil
            )
        }

        let host = BrowserReplHost.shared
        let session = host.registry.session(named: sessionID) {
            let bundle = host.bundle
            return BrowserReplSession(
                id: sessionID,
                cwd: cwd,
                bundle: bundle,
                driver: WebKitBrowserReplDriver(sessionID: sessionID, workspaceID: workspaceID, bundle: bundle)
            )
        }
        let outcome = await session.evaluate(
            code: code,
            dialect: dialect,
            cwd: cwd,
            timeout: .milliseconds(max(1, timeoutMilliseconds))
        )
        if named == nil {
            host.registry.reset(named: sessionID)
        }
        var payload: [String: Any] = [
            "session": named ?? NSNull(),
            "ok": outcome.error == nil,
            "output": outcome.lines.map { ["level": $0.level, "text": $0.text] },
            "duration_ms": outcome.durationMilliseconds,
        ]
        if let error = outcome.error { payload["error"] = error }
        return .ok(payload)
    }

    /// The workspace a new session binds to: `workspace_id` when given, else
    /// the selected workspace of the resolved window.
    private nonisolated func v2BrowserReplWorkspaceID(request: ControlRequest) async -> UUID? {
        await Task { @MainActor [weak self] () -> UUID? in
            guard let self else { return nil }
            let params = request.params.mapValues(\.foundationObject)
            guard let tabManager = self.v2ResolveTabManager(params: params) else { return nil }
            return self.v2ResolveWorkspace(params: params, tabManager: tabManager)?.id
        }.value
    }
}
