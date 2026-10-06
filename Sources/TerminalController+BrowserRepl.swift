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
/// A named session belongs to one workspace (`BrowserReplSessionKey`): the
/// workspace `workspace_id` names, else the caller's (`caller_workspace_id`),
/// else the focused one. `reset` and `list` act on that workspace unless
/// `all_workspaces` is true.
///
/// A session a client makes without `--session` (the interactive REPL and
/// `mcp`) carries the client's random `session_owner` token on every call,
/// and a one-shot run's session a token only this call holds: the registry
/// lists such a session, attaches to it and resets it only for that token,
/// so another local client that learns or guesses its name gets nothing.
/// A token comes only with such a client-made name (`cli-`, `mcp-`,
/// `oneshot-`): one with a shared name is refused, so no client can hide a
/// name others share.
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
            result = await v2BrowserReplReset(request: request)
        default:
            result = await v2BrowserReplList(request: request)
        }
        return v2Result(id: request.id?.foundationObject, result)
    }

    private nonisolated static var browserReplMissingSessionMessage: String {
        String(localized: "cli.browser.repl.error.sessionRequired", defaultValue: "A session name is required")
    }

    private nonisolated static var browserReplOwnedSessionMessage: String {
        String(
            localized: "cli.browser.repl.error.sessionOwned",
            defaultValue: "That REPL session belongs to another client; name a session with --session to share one"
        )
    }

    /// The longest `timeout_ms`, ``BrowserReplSession/maximumTimeout``.
    private nonisolated static var browserReplMaximumTimeoutMilliseconds: Int64 {
        BrowserReplSession.maximumTimeout.components.seconds * 1000
    }

    /// The caller's owner token for a session only it may use, or nil.
    private nonisolated static func browserReplOwner(_ params: [String: Any]) -> String? {
        (params["session_owner"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private nonisolated static var browserReplInvalidOwnerMessage: String {
        String(localized: "cli.browser.repl.error.sessionOwner", defaultValue: "A REPL session owner token is 1 to 128 bytes")
    }

    private nonisolated static var browserReplInvalidSessionNameMessage: String {
        String(
            localized: "cli.browser.repl.error.sessionName",
            defaultValue: "A session name is 1 to 64 characters: letters, digits, '.', '_' and '-'"
        )
    }

    /// `browser.repl.reset`: the caller's workspace's session of that name,
    /// or with `all_workspaces` the session of that name in every workspace.
    private nonisolated func v2BrowserReplReset(request: ControlRequest) async -> V2CallResult {
        let params = request.params.mapValues(\.foundationObject)
        let name = params["session"] as? String ?? ""
        guard !name.isEmpty else {
            return .err(code: "invalid_params", message: Self.browserReplMissingSessionMessage, data: nil)
        }
        guard BrowserReplSessionRegistry.isValidName(name) else {
            return .err(code: "invalid_params", message: Self.browserReplInvalidSessionNameMessage, data: nil)
        }
        let registry = BrowserReplHost.shared.registry
        let owner = Self.browserReplOwner(params)
        if params["all_workspaces"] as? Bool == true {
            let count = registry.reset(name: name, workspaceID: nil, owner: owner)
            return .ok(["session": name, "existed": count > 0, "count": count])
        }
        switch await v2BrowserReplResolvedWorkspace(params: params) {
        case .failure(let error):
            return error
        case .success(let workspaceID):
            let existed = registry.reset(BrowserReplSessionKey(workspaceID: workspaceID, name: name), owner: owner)
            return .ok(["session": name, "existed": existed, "count": existed ? 1 : 0, "workspace_id": workspaceID.uuidString])
        }
    }

    /// `browser.repl.list`: the caller's workspace's sessions, or with
    /// `all_workspaces` every workspace's.
    private nonisolated func v2BrowserReplList(request: ControlRequest) async -> V2CallResult {
        let params = request.params.mapValues(\.foundationObject)
        var workspaceID: UUID?
        if params["all_workspaces"] as? Bool != true {
            switch await v2BrowserReplResolvedWorkspace(params: params) {
            case .failure(let error):
                return error
            case .success(let id):
                workspaceID = id
            }
        }
        let sessions = BrowserReplHost.shared.registry.list(
            workspaceID: workspaceID,
            owner: Self.browserReplOwner(params)
        ).map { entry -> [String: Any] in
            [
                "session": entry.name,
                "workspace_id": entry.workspaceID.uuidString,
                "cwd": entry.cwd,
                "idle_seconds": entry.idleSeconds,
            ]
        }
        return .ok(["sessions": sessions])
    }

    /// The workspace a call acts on, or the error that ends the call.
    private enum BrowserReplWorkspaceResolution {
        case success(UUID)
        case failure(V2CallResult)
    }

    private nonisolated func v2BrowserReplResolvedWorkspace(params: [String: Any]) async -> BrowserReplWorkspaceResolution {
        switch await v2BrowserReplWorkspaceID(params: params) {
        case .success(let id):
            return .success(id)
        case .failure(.explicitWorkspaceNotFound(let id)):
            let prefix = String(localized: "cli.browser.repl.error.workspaceNotFound", defaultValue: "Workspace not found")
            return .failure(.err(code: "not_found", message: "\(prefix): \(id.uuidString)", data: nil))
        case .failure(.explicitWorkspaceInvalid(let handle)):
            let prefix = String(localized: "cli.browser.repl.error.workspaceInvalid", defaultValue: "Not a workspace in this cmux instance")
            return .failure(.err(code: "not_found", message: "\(prefix): \(handle.debugDescription)", data: nil))
        case .failure(.noFocusedWorkspace):
            return .failure(.err(
                code: "not_found",
                message: String(localized: "cli.browser.repl.error.workspace", defaultValue: "No workspace to bind the REPL session to"),
                data: nil
            ))
        }
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
        // Without a cwd a new session gets a temporary directory of its own;
        // the session refuses `/` and the home directory as roots.
        let cwd = (params["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        // The cwd and owner token are kept for the session's life, so they
        // are bounded before a session is made or attached.
        if let cwd, BrowserReplSession.workingDirectoryLengthRefusal(cwd) != nil {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.repl.error.cwdTooLong",
                    defaultValue: "The working directory path is longer than 1024 bytes; cd to a shorter path and run the command again"
                ),
                data: nil
            )
        }
        guard BrowserReplSessionRegistry.isValidOwner(Self.browserReplOwner(params)) else {
            return .err(code: "invalid_params", message: Self.browserReplInvalidOwnerMessage, data: nil)
        }
        // A running cell holds the session's thread until it ends or times
        // out, so the timeout is capped (BrowserReplSession.maximumTimeout).
        let requestedTimeout = params["timeout_ms"] as? NSNumber
        guard (requestedTimeout?.doubleValue ?? 0) <= Double(Self.browserReplMaximumTimeoutMilliseconds) else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.repl.error.timeoutTooLong",
                    defaultValue: "A REPL call's timeout is at most 600000 milliseconds (10 minutes)"
                ),
                data: nil
            )
        }
        let timeoutMilliseconds = requestedTimeout?.intValue ?? 120_000
        let named = (params["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let named, !BrowserReplSessionRegistry.isValidName(named) {
            return .err(code: "invalid_params", message: Self.browserReplInvalidSessionNameMessage, data: nil)
        }
        let sessionName = named ?? "oneshot-\(UUID().uuidString)"
        // A one-shot session is this call's alone: a token no client holds.
        let owner = named == nil ? UUID().uuidString : Self.browserReplOwner(params)

        let workspaceID: UUID
        switch await v2BrowserReplResolvedWorkspace(params: params) {
        case .success(let id):
            workspaceID = id
        case .failure(let error):
            return error
        }

        let host = BrowserReplHost.shared
        let bundle: BrowserReplRuntimeBundle
        switch host.bundle() {
        case .success(let loaded):
            bundle = loaded
        case .failure(let error):
            return .err(code: "unavailable", message: "Error: \(error.description)", data: nil)
        }
        // A named session is the caller's workspace's: the same name in
        // another workspace is another session. Each instance gets an id of
        // its own, so driver state never outlives it into a later session
        // of the same name.
        let key = BrowserReplSessionKey(workspaceID: workspaceID, name: sessionName)
        let session: BrowserReplSession
        do {
            session = try host.registry.session(for: key, owner: owner) { instanceID in
                BrowserReplSession(
                    id: sessionName,
                    cwd: cwd,
                    bundle: bundle,
                    driver: WebKitBrowserReplDriver(sessionID: instanceID, workspaceID: workspaceID, bundle: bundle)
                )
            }
        } catch BrowserReplSessionRegistry.Refusal.tooManySessions(let limit) {
            let prefix = String(
                localized: "cli.browser.repl.error.tooManySessions",
                defaultValue: "Too many browser REPL sessions are open; reset one with `cmux browser repl reset NAME` (`cmux browser repl list --all-workspaces` lists them)"
            )
            return .err(code: "unavailable", message: "\(prefix) (\(limit))", data: nil)
        } catch BrowserReplSessionRegistry.Refusal.ownedByAnotherClient {
            return .err(code: "invalid_params", message: Self.browserReplOwnedSessionMessage, data: nil)
        } catch BrowserReplSessionRegistry.Refusal.invalidOwner {
            return .err(code: "invalid_params", message: Self.browserReplInvalidOwnerMessage, data: nil)
        } catch BrowserReplSessionRegistry.Refusal.ownerOnSharedName {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.repl.error.sessionOwnerShared",
                    defaultValue: "A named REPL session is shared by name and takes no owner token; send session_owner only with a session name the client made for itself (cli-, mcp- or oneshot-)"
                ),
                data: nil
            )
        } catch {
            return .err(code: "invalid_params", message: Self.browserReplInvalidSessionNameMessage, data: nil)
        }
        let outcome = await session.evaluate(
            code: code,
            cwd: cwd,
            timeout: .milliseconds(max(1, timeoutMilliseconds)),
            maxOutput: (params["max_output"] as? NSNumber)?.intValue
        )
        if named == nil {
            host.registry.reset(key, owner: owner)
        }
        var payload: [String: Any] = [
            "session": named ?? NSNull(),
            "workspace_id": workspaceID.uuidString,
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
        // Present is explicit, whatever it holds: one that is not a
        // workspace id fails instead of falling back.
        let explicit: String? = params["workspace_id"].flatMap { value in
            value is NSNull ? nil : (value as? String) ?? String(describing: value)
        }
        let caller = v2UUID(params, "caller_workspace_id")
        return await Task { @MainActor [weak self] () -> Result<UUID, BrowserReplWorkspaceBinding.Failure> in
            BrowserReplWorkspaceBinding(
                exists: { AppDelegate.shared?.workspaceFor(tabId: $0) != nil },
                focused: {
                    let manager = AppDelegate.shared?.currentScriptableMainWindow()?.tabManager ?? self?.tabManager
                    guard let manager, let selected = manager.selectedTabId,
                          manager.tabs.contains(where: { $0.id == selected }) else { return nil }
                    return selected
                }
            ).resolve(explicitHandle: explicit, caller: caller)
        }.value
    }
}
