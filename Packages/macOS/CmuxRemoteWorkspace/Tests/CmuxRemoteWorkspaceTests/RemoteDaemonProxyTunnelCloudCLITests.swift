import CmuxFoundation
import Darwin
import Foundation
import Testing
import CmuxRemoteDaemon
@testable import CmuxRemoteWorkspace

/// One-shot unix socket server standing in for the local cmux socket: records
/// every byte a bridge client writes, answers the first line as a successful
/// `auth.login`, and answers end-of-input with a successful response.
private final class RecordingLocalSocketServer: @unchecked Sendable {
    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var _received = Data()
    private let finished = DispatchSemaphore(value: 0)

    var received: Data {
        lock.lock()
        defer { lock.unlock() }
        return _received
    }

    init() throws {
        path = NSTemporaryDirectory() + "cmux-bridge-test-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "RecordingLocalSocketServer", code: Int(errno))
        }
        // Set on the listener so every accepted socket inherits it. Setting it
        // after accept fails with EINVAL once the client has already closed,
        // and the reply write would then raise SIGPIPE in the test process.
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { raw in
            pathBytes.withUnsafeBytes { source in
                raw.baseAddress!.advanced(by: offset).copyMemory(from: source.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let length = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            let failure = errno
            Darwin.close(fd)
            throw NSError(domain: "RecordingLocalSocketServer", code: Int(failure))
        }
        listenFD = fd
        Thread.detachNewThread { [self] in
            defer { finished.signal() }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            // Darwin refuses socket options with EINVAL once a client has
            // hung up before accept, so a write there would raise SIGPIPE and
            // kill the test process. Only a socket that took SO_NOSIGPIPE is
            // answered; the other has no reader left.
            var noSigPipe: Int32 = 1
            let canWrite = setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)
            ) == 0
            var answeredAuth = false
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(client, &scratch, scratch.count)
                guard count > 0 else { break }
                lock.lock()
                _received.append(scratch, count: count)
                let sawLine = _received.contains(0x0A)
                lock.unlock()
                if sawLine, !answeredAuth, canWrite {
                    answeredAuth = true
                    Self.write("{\"ok\":true}\n", to: client)
                }
            }
            if canWrite {
                Self.write("{\"ok\":true,\"result\":{}}\n", to: client)
            }
        }
    }

    private static func write(_ line: String, to fd: Int32) {
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    func waitUntilFinished(timeout: TimeInterval = 5) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    func close() {
        Darwin.close(listenFD)
        unlink(path)
    }
}

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

    @Test("the bridge writes no password or request to a local socket run by another user")
    func foreignLocalSocketPeerReceivesNothing() throws {
        let localSocket = try RecordingLocalSocketServer()
        defer { localSocket.close() }
        let request = try jsonData([
            "id": "bridge-test",
            "method": "notification.create",
            "params": ["title": "t"],
        ]) + Data([0x0A])

        // No second local account exists in tests, so expect a user ID the
        // fake socket's owner cannot have; the bridge must treat it as foreign.
        #expect(throws: (any Error).self) {
            _ = try RemoteDaemonProxyTunnel.roundTripUnixSocket(
                socketPath: localSocket.path,
                request: request,
                peerCheck: UnixSocketPeerCheck(expectedUserID: geteuid() &+ 1),
                socketPassword: { "bridge-secret" }
            )
        }

        #expect(localSocket.waitUntilFinished())
        #expect(localSocket.received.isEmpty, "The bridge must not write to a socket another user listens on")
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let trimmed = Data(data.split(separator: 0x0A).first ?? data[...])
        return try #require(JSONSerialization.jsonObject(with: trimmed, options: []) as? [String: Any])
    }
}
