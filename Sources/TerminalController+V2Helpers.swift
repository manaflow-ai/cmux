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


// MARK: - V2 encoding and result plumbing helpers
extension TerminalController {
    /// Wire-protocol helpers (parse/encode) shared with the package;
    /// stateless, so single instances serve every thread.
    nonisolated static let v2Parser = ControlRequestParser()
    nonisolated static let v2Encoder = ControlResponseEncoder()

    nonisolated static func executionPolicy(forV2Method method: String) -> ControlCommandExecutionPolicy {
        ControlCommandExecutionPolicy(forMethod: method)
    }

    nonisolated func v2AuthStatusPayload(timedOut: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        v2MainSync {
            MainActor.assumeIsolated {
                guard let coordinator = self.authCoordinator else {
                    result = [
                        "signed_in": false,
                        "is_restoring_session": false,
                        "is_loading": false,
                        "timed_out": timedOut
                    ]
                    return
                }
                let isSigningIn = self.browserSignInFlow?.isSigningIn ?? false
                var status: [String: Any] = [
                    "signed_in": coordinator.isAuthenticated,
                    "is_restoring_session": coordinator.isRestoringSession,
                    "is_loading": coordinator.isLoading || isSigningIn,
                    "timed_out": timedOut
                ]
                if let user = coordinator.currentUser {
                    var userDict: [String: Any] = ["id": user.id]
                    if let email = user.primaryEmail { userDict["email"] = email }
                    if let name = user.displayName { userDict["display_name"] = name }
                    status["user"] = userDict
                }
                if let teamID = coordinator.resolvedTeamID {
                    status["selected_team_id"] = teamID
                }
                if !coordinator.availableTeams.isEmpty {
                    status["teams"] = coordinator.availableTeams.map { team -> [String: Any] in
                        var dict: [String: Any] = [
                            "id": team.id,
                            "display_name": team.displayName
                        ]
                        if let slug = team.slug { dict["slug"] = slug }
                        return dict
                    }
                }
                result = status
            }
        }
        return result
    }

    nonisolated func v2OrNull(_ value: Any?) -> Any {
        // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
        if let value { return value }
        return NSNull()
    }

    static func notificationCreatedAtString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func notificationListTrailingField(_ value: String) -> String {
        "pct:" + value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\r", with: "%0D")
    }

    nonisolated func v2NonEmptyString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func v2MainSync<T>(_ body: @MainActor () -> T) -> T {
        let policyStack = Self.currentSocketCommandFocusAllowanceStack()
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                Self.withSocketCommandPolicyStack(policyStack) {
                    body()
                }
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                Self.withSocketCommandPolicyStack(policyStack) {
                    body()
                }
            }
        }
    }

    nonisolated func v2Ok(id: Any?, result: Any) -> String {
        guard let idValue = Self.v2WireId(id),
              let payload = JSONValue(foundationObject: result) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.ok(id: idValue, result: payload)
    }

    /// Bridges a legacy `Any?` request id to the wire value: missing ids
    /// encode as JSON `null`; an unencodable id reports overall encode
    /// failure (the legacy `isValidJSONObject` behavior).
    private nonisolated static func v2WireId(_ id: Any?) -> JSONValue? {
        guard let id else { return .null }
        return JSONValue(foundationObject: id)
    }

    /// Bridge an async throws closure into a socket RPC response. Runs the work on a detached
    /// Task (so VMClient's URLSession hops are free to use any actor) and blocks the socket
    /// worker thread on a semaphore. Mirrors the auth.begin_sign_in pattern above.
    nonisolated func v2VmCall(
        id: Any?,
        timeoutSeconds: TimeInterval = 17 * 60,
        _ work: @escaping () async throws -> [String: Any]
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<[String: Any], Error>?
        let task = Task {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "VM request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        switch result {
        case .success(let payload):
            return v2Ok(id: id, result: payload)
        case .failure(let error):
            return v2Error(
                id: id,
                code: "vm_error",
                message: String(describing: error)
            )
        case nil:
            return v2Error(
                id: id,
                code: "vm_error",
                message: "unknown vm error"
            )
        }
    }

    nonisolated func v2AsyncResultCall(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ work: @escaping () async -> V2CallResult
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult?
        let task = Task {
            result = await work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "Request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        guard let result else {
            return v2Error(
                id: id,
                code: "request_error",
                message: "Request failed before returning a result"
            )
        }
        return v2Result(id: id, result)
    }

    nonisolated func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        guard let idValue = Self.v2WireId(id) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        var dataValue: JSONValue?
        if let data {
            guard let bridgedData = JSONValue(foundationObject: data) else {
                return ControlResponseEncoder.encodeFailureResponse
            }
            dataValue = bridgedData
        }
        return Self.v2Encoder.error(id: idValue, code: code, message: message, data: dataValue)
    }

    /// Interim `Any`-shaped twin of the package's `ControlCallResult`, kept
    /// while the command bodies still build Foundation payloads. Bodies
    /// migrate onto the typed DTO in the ControlCommandCoordinator stage.
    enum V2CallResult {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }

    nonisolated func v2Result(id: Any?, _ res: V2CallResult) -> String {
        switch res {
        case .ok(let payload):
            return v2Ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    nonisolated func v2UnsupportedWorkspaceAliasError(method: String, params: [String: Any]) -> V2CallResult? {
        guard method.hasPrefix("workspace."), params.keys.contains("window") else { return nil }
        return .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.unsupportedWindowParam",
                defaultValue: "Unsupported parameter `window`; use `window_id` with a window UUID or ref from `window.list`."
            ),
            data: [
                "method": method,
                "unsupported_param": "window",
                "supported_param": "window_id"
            ]
        )
    }

    nonisolated func v2Encode(_ object: Any) -> String {
        guard let value = JSONValue(foundationObject: object) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.encode(value)
    }

    private func v2EnsureHandleRef(kind: ControlHandleKind, uuid: UUID) -> String {
        v2Handles.ensureRef(kind: kind, uuid: uuid)
    }

    func v2ResolveHandleRef(_ handle: String) -> UUID? {
        v2Handles.uuid(forRef: handle)
    }

    func v2Ref(kind: ControlHandleKind, uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        return v2EnsureHandleRef(kind: kind, uuid: uuid)
    }

    func v2WorkspaceRefs(for ids: [UUID]) -> [UUID: String] {
        var refs: [UUID: String] = [:]
        refs.reserveCapacity(ids.count)
        for id in ids {
            refs[id] = v2EnsureHandleRef(kind: .workspace, uuid: id)
        }
        return refs
    }

    func v2WorkspacePaneAndSurfaceRefs(
        workspaceId: UUID,
        paneId: UUID?,
        surfaceId: UUID
    ) -> (workspaceRef: String, paneRef: String?, surfaceRef: String) {
        return (
            workspaceRef: v2EnsureHandleRef(kind: .workspace, uuid: workspaceId),
            paneRef: paneId.map { v2EnsureHandleRef(kind: .pane, uuid: $0) },
            surfaceRef: v2EnsureHandleRef(kind: .surface, uuid: surfaceId)
        )
    }

    func v2TabRef(uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: uuid)
        return surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
    }

    func v2BrowserDisabledExternalOpenResult(
        rawURL: String? = nil,
        url: URL?,
        tabManager: TabManager?
    ) -> V2CallResult {
        if let rawURL, url == nil {
            return .err(
                code: "invalid_params",
                message: "Invalid URL",
                data: ["url": rawURL]
            )
        }
        guard let url else {
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        }

        var result: V2CallResult = .err(
            code: "external_open_failed",
            message: "Failed to open URL externally",
            data: ["url": url.absoluteString]
        )
        v2MainSync {
            guard NSWorkspace.shared.open(url) else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": v2OrNull(nil),
                "workspace_ref": v2Ref(kind: .workspace, uuid: nil),
                "pane_id": v2OrNull(nil),
                "pane_ref": v2Ref(kind: .pane, uuid: nil),
                "surface_id": v2OrNull(nil),
                "surface_ref": v2Ref(kind: .surface, uuid: nil),
                "created_split": false,
                "opened_externally": true,
                "browser_disabled": true,
                "placement_strategy": "external_browser_disabled",
                "url": url.absoluteString
            ])
        }
        return result
    }

    func v2RefreshKnownRefs() {
        guard let app = AppDelegate.shared else { return }

        let windows = app.listMainWindowSummaries()
        for item in windows {
            _ = v2EnsureHandleRef(kind: .window, uuid: item.windowId)
            if let tm = app.tabManagerFor(windowId: item.windowId) {
                for ws in tm.tabs {
                    _ = v2EnsureHandleRef(kind: .workspace, uuid: ws.id)
                    for paneId in ws.bonsplitController.allPaneIds {
                        _ = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
                    }
                    for panelId in ws.panels.keys {
                        _ = v2EnsureHandleRef(kind: .surface, uuid: panelId)
                    }
                }
                // Mint workspace_group refs for groups that exist before any
                // workspace.group.* call so callers can pass `workspace_group:N`
                // immediately after restore (otherwise the first ref hand-off
                // happens only on `list`/`create`).
                for group in tm.workspaceGroups {
                    _ = v2EnsureHandleRef(kind: .workspaceGroup, uuid: group.id)
                }
            }
        }
    }

    // MARK: - V2 Context Resolution

}
