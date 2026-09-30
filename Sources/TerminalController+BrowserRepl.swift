import CmuxBrowser
import CmuxControlSocket
import Foundation

/// Process-wide REPL state: live sessions and the bundled runtime.
final class BrowserReplHost: @unchecked Sendable {
    static let shared = BrowserReplHost()

    let registry = BrowserReplSessionRegistry()
    private let lock = NSLock()
    private var cachedBundle: Result<BrowserReplRuntimeBundle, BrowserReplRuntimeBundleError>?

    /// The runtime bundled in the app, in the order its `manifest.json`
    /// gives. `CMUX_BROWSER_REPL_RUNTIME_DIR` points a development build at a
    /// source checkout instead, re-read per session.
    func bundle() -> Result<BrowserReplRuntimeBundle, BrowserReplRuntimeBundleError> {
        if let override = ProcessInfo.processInfo.environment["CMUX_BROWSER_REPL_RUNTIME_DIR"], !override.isEmpty {
            return Self.load(URL(fileURLWithPath: override, isDirectory: true))
        }
        return lock.withLock {
            if let cachedBundle { return cachedBundle }
            let directory = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("browser-repl", isDirectory: true)
            let loaded = Self.load(directory)
            cachedBundle = loaded
            return loaded
        }
    }

    private static func load(_ directory: URL) -> Result<BrowserReplRuntimeBundle, BrowserReplRuntimeBundleError> {
        do {
            return .success(try BrowserReplRuntimeBundle.load(from: directory))
        } catch let error as BrowserReplRuntimeBundleError {
            return .failure(error)
        } catch {
            return .failure(.manifestMissing(path: directory.appendingPathComponent(BrowserReplRuntimeBundle.manifestName).path))
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
        let cwd = (params["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-repl").path
        let timeoutMilliseconds = (params["timeout_ms"] as? NSNumber)?.intValue ?? 120_000
        let named = (params["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sessionID = named ?? "oneshot-\(UUID().uuidString)"

        let workspaceID: UUID
        switch await v2BrowserReplWorkspaceID(params: params) {
        case .success(let id):
            workspaceID = id
        case .failure(.explicitWorkspaceNotFound(let id)):
            let prefix = String(localized: "cli.browser.repl.error.workspaceNotFound", defaultValue: "Workspace not found")
            return .err(code: "not_found", message: "\(prefix): \(id.uuidString)", data: nil)
        case .failure(.noFocusedWorkspace):
            return .err(
                code: "not_found",
                message: String(localized: "cli.browser.repl.error.workspace", defaultValue: "No workspace to bind the REPL session to"),
                data: nil
            )
        }

        let host = BrowserReplHost.shared
        let bundle: BrowserReplRuntimeBundle
        switch host.bundle() {
        case .success(let loaded):
            bundle = loaded
        case .failure(let error):
            return .err(code: "unavailable", message: "Error: \(error.description)", data: nil)
        }
        let session = host.registry.session(named: sessionID) {
            BrowserReplSession(
                id: sessionID,
                cwd: cwd,
                bundle: bundle,
                driver: WebKitBrowserReplDriver(sessionID: sessionID, workspaceID: workspaceID, bundle: bundle)
            )
        }
        let outcome = await session.evaluate(
            code: code,
            cwd: cwd,
            timeout: .milliseconds(max(1, timeoutMilliseconds)),
            maxOutput: (params["max_output"] as? NSNumber)?.intValue
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

    /// The workspace a new session binds to. `workspace_id` is an explicit
    /// choice and must exist; `caller_workspace_id` (the CLI's
    /// `CMUX_WORKSPACE_ID`) falls back to the focused workspace of the key or
    /// frontmost window when this instance does not know it.
    private nonisolated func v2BrowserReplWorkspaceID(
        params: [String: Any]
    ) async -> Result<UUID, BrowserReplWorkspaceBinding.Failure> {
        let explicit = v2UUID(params, "workspace_id")
        let caller = v2UUID(params, "caller_workspace_id")
        return await Task { @MainActor [weak self] () -> Result<UUID, BrowserReplWorkspaceBinding.Failure> in
            BrowserReplWorkspaceBinding.resolve(
                explicit: explicit,
                caller: caller,
                exists: { AppDelegate.shared?.workspaceFor(tabId: $0) != nil },
                focused: {
                    let manager = AppDelegate.shared?.currentScriptableMainWindow()?.tabManager ?? self?.tabManager
                    guard let manager, let selected = manager.selectedTabId,
                          manager.tabs.contains(where: { $0.id == selected }) else { return nil }
                    return selected
                }
            )
        }.value
    }
}
