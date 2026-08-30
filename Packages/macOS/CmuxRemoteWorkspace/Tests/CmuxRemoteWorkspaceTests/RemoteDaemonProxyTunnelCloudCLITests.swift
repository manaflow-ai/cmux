import Foundation
import Testing
import CmuxRemoteDaemon
@testable import CmuxRemoteWorkspace

@Suite("RemoteDaemonProxyTunnel cloud CLI bridge")
struct RemoteDaemonProxyTunnelCloudCLITests {
    private let strings = RemoteDaemonStrings(
        missingPersistentPTYCapability: "persistent-pty",
        missingRequiredFunctionality: "generic",
        cloudNotificationClearWorkspaceInvalid: "clear workspace invalid",
        cloudNotificationClearWorkspaceDenied: "clear workspace denied",
        cloudNotificationClearSurfaceInvalid: "clear surface invalid",
        cloudNotificationClearCallerInvalid: "clear caller invalid",
        cloudNotificationClearCallerSelectorsRequireCaller: "clear caller selectors require caller",
        cloudNotificationClearCallerScopeConflict: "clear caller scope conflict",
        cloudNotificationClearEncodingFailed: "clear encoding failed"
    )

    @Test("notify for caller is rewritten to an explicit workspace and surface target")
    func notifyForCallerIsScopedAndForwarded() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let request = try jsonData([
            "id": "request-1",
            "method": "notification.create_for_caller",
            "params": [
                "preferred_workspace_id": workspaceID.uuidString,
                "preferred_surface_id": surfaceID.uuidString,
                "title": "cmux",
                "subtitle": "cloud",
                "body": "done",
                "prefer_tty": true,
            ],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: workspaceID,
            strings: strings
        )

        guard case .forward(let forwarded) = validation else {
            Issue.record("expected request to be forwarded")
            return
        }
        let envelope = try jsonObject(forwarded)
        #expect(envelope["id"] as? String == "request-1")
        #expect(envelope["method"] as? String == "notification.create_for_target")
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == workspaceID.uuidString)
        #expect(params["surface_id"] as? String == surfaceID.uuidString)
        #expect(params["title"] as? String == "cmux")
        #expect(params["subtitle"] as? String == "cloud")
        #expect(params["body"] as? String == "done")
        #expect(params["prefer_tty"] == nil)
    }

    @Test("unscoped notify is rejected before the local socket")
    func unscopedNotifyIsRejected() throws {
        let workspaceID = UUID()
        let request = try jsonData([
            "id": "request-owner",
            "method": "notification.create",
            "params": [
                "title": "cmux",
                "body": "done",
            ],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: workspaceID,
            strings: strings
        )

        guard case .reject(let response) = validation else {
            Issue.record("expected request to be rejected")
            return
        }
        let envelope = try jsonObject(response)
        #expect(envelope["id"] as? String == "request-owner")
        #expect(envelope["ok"] as? Bool == false)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
    }

    @Test("notify targeting another workspace is rejected before the local socket")
    func crossWorkspaceNotifyIsRejected() throws {
        let ownerWorkspaceID = UUID()
        let otherWorkspaceID = UUID()
        let surfaceID = UUID()
        let request = try jsonData([
            "id": "request-2",
            "method": "notification.create_for_caller",
            "params": [
                "preferred_workspace_id": otherWorkspaceID.uuidString,
                "preferred_surface_id": surfaceID.uuidString,
                "title": "cmux",
            ],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: ownerWorkspaceID,
            strings: strings
        )

        guard case .reject(let response) = validation else {
            Issue.record("expected request to be rejected")
            return
        }
        let envelope = try jsonObject(response)
        #expect(envelope["id"] as? String == "request-2")
        #expect(envelope["ok"] as? Bool == false)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "remote_cli_workspace_denied")
    }

    @Test("surface-scoped notification clear is forwarded only for the owner workspace")
    func surfaceScopedNotificationClearIsForwarded() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let request = try jsonData([
            "id": "clear-1",
            "method": "notification.clear",
            "params": [
                "caller": true,
                "preferred_workspace_id": workspaceID.uuidString,
                "preferred_surface_id": surfaceID.uuidString,
            ],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: workspaceID,
            strings: strings
        )

        guard case .forward(let forwarded) = validation else {
            Issue.record("expected scoped clear to be forwarded")
            return
        }
        let envelope = try jsonObject(forwarded)
        #expect(envelope["method"] as? String == "notification.clear")
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == workspaceID.uuidString)
        #expect(params["surface_id"] as? String == surfaceID.uuidString)
        #expect(params["caller"] == nil)
    }

    @Test("workspace-wide notification clear is rejected by the cloud bridge")
    func workspaceWideNotificationClearIsRejected() throws {
        let workspaceID = UUID()
        let request = try jsonData([
            "id": "clear-2",
            "method": "notification.clear",
            "params": ["workspace_id": workspaceID.uuidString],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: workspaceID,
            strings: strings
        )

        guard case .reject(let response) = validation else {
            Issue.record("expected workspace-wide clear to be rejected")
            return
        }
        let envelope = try jsonObject(response)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
        #expect(error["message"] as? String == strings.cloudNotificationClearSurfaceInvalid)
    }

    @Test("invalid surface notification clear uses the injected localized message")
    func invalidSurfaceNotificationClearUsesLocalizedMessage() throws {
        let workspaceID = UUID()
        let request = try jsonData([
            "id": "clear-3",
            "method": "notification.clear",
            "params": [
                "workspace_id": workspaceID.uuidString,
                "surface_id": "not-a-surface",
            ],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: workspaceID,
            strings: strings
        )
        guard case .reject(let response) = validation else {
            Issue.record("expected invalid surface clear to be rejected")
            return
        }
        let envelope = try jsonObject(response)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
        #expect(error["message"] as? String == strings.cloudNotificationClearSurfaceInvalid)
    }

    @Test("notification clear rejects a non-boolean caller selector")
    func notificationClearRejectsInvalidCallerType() throws {
        let workspaceID = UUID()
        let request = try jsonData([
            "id": "clear-invalid-caller",
            "method": "notification.clear",
            "params": [
                "caller": ["unexpected": true],
                "workspace_id": workspaceID.uuidString,
                "surface_id": UUID().uuidString,
            ],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: workspaceID,
            strings: strings
        )

        guard case .reject(let response) = validation else {
            Issue.record("invalid caller value must be rejected")
            return
        }
        let envelope = try jsonObject(response)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
        #expect(error["message"] as? String == strings.cloudNotificationClearCallerInvalid)
    }

    @Test("notification clear rejects conflicting caller and explicit selectors")
    func notificationClearRejectsConflictingSelectors() throws {
        let workspaceID = UUID()
        for selector in ["workspace_id", "tab_id", "surface_id"] {
            let request = try jsonData([
                "id": "clear-conflict-\(selector)",
                "method": "notification.clear",
                "params": [
                    "caller": true,
                    "preferred_workspace_id": workspaceID.uuidString,
                    "preferred_surface_id": UUID().uuidString,
                    selector: workspaceID.uuidString,
                ],
            ])

            let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
                request,
                ownerWorkspaceID: workspaceID,
                strings: strings
            )

            guard case .reject(let response) = validation else {
                Issue.record("caller plus \(selector) must be rejected")
                continue
            }
            let envelope = try jsonObject(response)
            let error = try #require(envelope["error"] as? [String: Any])
            #expect(error["code"] as? String == "invalid_params")
            #expect(error["message"] as? String == strings.cloudNotificationClearCallerScopeConflict)
        }
    }

    @Test("notification clear rejects caller-only selectors without caller mode")
    func notificationClearRejectsCallerOnlySelectorsWithoutCaller() throws {
        let workspaceID = UUID()
        let request = try jsonData([
            "id": "clear-caller-only",
            "method": "notification.clear",
            "params": [
                "preferred_workspace_id": workspaceID.uuidString,
                "preferred_surface_id": UUID().uuidString,
            ],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: workspaceID,
            strings: strings
        )

        guard case .reject(let response) = validation else {
            Issue.record("caller-only selectors without caller=true must be rejected")
            return
        }
        let envelope = try jsonObject(response)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
        #expect(error["message"] as? String == strings.cloudNotificationClearCallerSelectorsRequireCaller)
    }

    @Test("non-notification methods are rejected before the local socket")
    func arbitraryLocalSocketMethodsAreRejected() throws {
        let request = try jsonData([
            "id": "request-3",
            "method": "surface.send_text",
            "params": [
                "workspace_id": UUID().uuidString,
                "surface_id": UUID().uuidString,
                "text": "echo pwned\n",
            ],
        ])

        let validation = RemoteDaemonProxyTunnel.validateCloudCLIRequest(
            request,
            ownerWorkspaceID: UUID(),
            strings: strings
        )

        guard case .reject(let response) = validation else {
            Issue.record("expected request to be rejected")
            return
        }
        let envelope = try jsonObject(response)
        #expect(envelope["ok"] as? Bool == false)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "remote_cli_method_denied")
    }

    @Test("socket auth request is JSON-RPC auth.login")
    func authLoginRequestUsesSocketAuthProtocol() throws {
        let request = try RemoteDaemonProxyTunnel.cloudCLIAuthLoginRequest(password: "secret")
        let envelope = try jsonObject(request)
        #expect(envelope["id"] as? String == "cloud-cli-auth")
        #expect(envelope["method"] as? String == "auth.login")
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(params["password"] as? String == "secret")
        #expect(RemoteDaemonProxyTunnel.cloudCLIAuthResponseSucceeded(Data(#"{"ok":true,"result":{"authenticated":true}}"#.utf8)))
        #expect(!RemoteDaemonProxyTunnel.cloudCLIAuthResponseSucceeded(Data(#"{"ok":false,"error":{"code":"unauthorized"}}"#.utf8)))
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let trimmed = Data(data.split(separator: 0x0A).first ?? data[...])
        return try #require(JSONSerialization.jsonObject(with: trimmed, options: []) as? [String: Any])
    }
}
