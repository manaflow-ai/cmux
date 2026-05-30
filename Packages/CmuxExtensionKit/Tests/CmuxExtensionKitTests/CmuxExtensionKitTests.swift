import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

@Suite
struct CMUXExtensionKitTests {
    @Test
    func testSidebarSnapshotRoundTripsStableContract() throws {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let snapshot = CMUXSidebarSnapshot(
            sequence: 42,
            windowID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            selectedWorkspaceID: workspaceID,
            grantedReadScopes: [.workspaceMetadata, .workspacePaths, .notifications, .networkPorts, .pullRequests],
            grantedActionScopes: [.selectWorkspace],
            workspaces: [
                CMUXSidebarWorkspace(
                    id: workspaceID,
                    title: "Build",
                    detail: "main",
                    isPinned: true,
                    rootPath: "/repo",
                    projectRootPath: "/repo",
                    gitBranch: "main",
                    unreadCount: 2,
                    latestNotification: "Tests passed",
                    listeningPorts: [3000],
                    pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/1"]
                ),
            ]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CMUXSidebarSnapshot.self, from: encoded)

        #expect(decoded == snapshot)
        #expect(decoded.apiVersion == CMUXExtensionAPIVersion.sidebarV1)
        #expect(decoded.grantedReadScopes.contains(.workspaceMetadata))
        #expect(decoded.grantedActionScopes == [.selectWorkspace])
    }

    @Test
    func testManifestValidationAcceptsSidebarV1() throws {
        let manifest = CMUXExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Example Sidebar",
            requestedScopes: [.workspaceMetadata, .workspacePaths],
            requestedActionScopes: [.selectWorkspace, .openURL]
        )

        try validateSidebarManifest(manifest)
    }

    @Test
    func testManifestDecodingDefaultsMissingActionScopesToNone() throws {
        let payload = Data("""
        {
          "id": "dev.example.sidebar",
          "displayName": "Example Sidebar",
          "kind": "sidebar",
          "minimumAPIVersion": { "major": 1, "minor": 0 },
          "requestedScopes": ["workspaceMetadata"]
        }
        """.utf8)

        let manifest = try JSONDecoder().decode(CMUXExtensionManifest.self, from: payload)

        #expect(manifest.requestedScopes == [.workspaceMetadata])
        #expect(manifest.requestedActionScopes.isEmpty)
        try validateSidebarManifest(manifest)
    }

    @Test
    func testManifestInitializerDefaultsActionScopesToNone() throws {
        let manifest = CMUXExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Example Sidebar"
        )

        #expect(manifest.requestedScopes.isEmpty)
        #expect(manifest.requestedActionScopes.isEmpty)
        try validateSidebarManifest(manifest)
    }

    @Test
    func testSidebarSnapshotFilteringRemovesUngrantedScopeData() throws {
        let workspaceID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let snapshot = CMUXSidebarSnapshot(
            sequence: 44,
            selectedWorkspaceID: workspaceID,
            workspaces: [
                CMUXSidebarWorkspace(
                    id: workspaceID,
                    title: "Build",
                    detail: "Running tests",
                    isPinned: true,
                    rootPath: "/Users/example/secret",
                    projectRootPath: "/Users/example/secret",
                    gitBranch: "feature/sidebar",
                    unreadCount: 2,
                    latestNotification: "Private notification",
                    listeningPorts: [3000, 5173],
                    pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/4994"]
                ),
            ]
        )

        let filtered = snapshot.filtered(for: [CMUXExtensionScope.workspaceMetadata])
        let workspace = try #require(filtered.workspaces.first)

        #expect(filtered.grantedReadScopes == [.workspaceMetadata])
        #expect(filtered.grantedActionScopes.isEmpty)
        #expect(workspace.id == workspaceID)
        #expect(workspace.title == "Build")
        #expect(workspace.detail == "Running tests")
        #expect(workspace.gitBranch == "feature/sidebar")
        #expect(workspace.unreadCount == 2)
        #expect(workspace.rootPath == nil)
        #expect(workspace.projectRootPath == nil)
        #expect(workspace.latestNotification == nil)
        #expect(workspace.listeningPorts.isEmpty)
        #expect(workspace.pullRequestURLs.isEmpty)
    }

    @Test
    func testSidebarSnapshotFilteringWithNoScopesRemovesWorkspaceMetadata() {
        let workspaceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let windowID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let snapshot = CMUXSidebarSnapshot(
            sequence: 45,
            windowID: windowID,
            selectedWorkspaceID: workspaceID,
            workspaces: [
                CMUXSidebarWorkspace(
                    id: workspaceID,
                    title: "Private Workspace",
                    detail: "Sensitive detail",
                    isPinned: true,
                    rootPath: "/Users/example/private",
                    projectRootPath: "/Users/example/private",
                    gitBranch: "secret",
                    unreadCount: 9,
                    latestNotification: "Sensitive notification",
                    listeningPorts: [8080],
                    pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/4994"]
                ),
            ]
        )

        let filtered = snapshot.filtered(for: [CMUXExtensionScope]())

        #expect(filtered.apiVersion == .sidebarV1)
        #expect(filtered.sequence == 45)
        #expect(filtered.windowID == nil)
        #expect(filtered.selectedWorkspaceID == nil)
        #expect(filtered.grantedReadScopes.isEmpty)
        #expect(filtered.grantedActionScopes.isEmpty)
        #expect(filtered.workspaces.isEmpty)
    }

    @Test
    func testSidebarSnapshotDecodingDefaultsMissingGrantedScopes() throws {
        let payload = Data("""
        {
          "apiVersion": { "major": 1, "minor": 0 },
          "sequence": 50,
          "selectedWorkspaceID": null,
          "workspaces": []
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(CMUXSidebarSnapshot.self, from: payload)

        #expect(snapshot.sequence == 50)
        #expect(snapshot.grantedReadScopes.isEmpty)
        #expect(snapshot.grantedActionScopes.isEmpty)
    }

    @Test
    func testSidebarXPCCodecRoundTripsSnapshotActionAndResult() throws {
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let snapshot = CMUXSidebarSnapshot(
            sequence: 43,
            selectedWorkspaceID: workspaceID,
            workspaces: [
                CMUXSidebarWorkspace(
                    id: workspaceID,
                    title: "Build",
                    detail: "Running tests",
                    isPinned: true,
                    rootPath: "/tmp/cmux",
                    projectRootPath: "/tmp/cmux",
                    gitBranch: "feature/sidebar",
                    unreadCount: 2,
                    latestNotification: "Tests failed",
                    listeningPorts: [3000],
                    pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/4994"]
                ),
            ]
        )
        let decodedSnapshot = try CMUXSidebarXPCCodec.decodeSnapshot(
            try CMUXSidebarXPCCodec.encodeSnapshot(snapshot)
        )
        #expect(decodedSnapshot == snapshot)

        let actionScopedSnapshot = snapshot.filtered(
            for: [CMUXExtensionScope.workspaceMetadata],
            actionScopes: [CMUXExtensionActionScope.selectWorkspace]
        )
        #expect(actionScopedSnapshot.grantedActionScopes == [.selectWorkspace])

        let manifest = CMUXExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Example Sidebar",
            requestedScopes: [.workspaceMetadata, .networkPorts],
            requestedActionScopes: [.selectWorkspace, .closeWorkspace]
        )
        let decodedManifest = try CMUXSidebarXPCCodec.decodeManifest(
            try CMUXSidebarXPCCodec.encodeManifest(manifest)
        )
        #expect(decodedManifest == manifest)

        let action = CMUXSidebarAction.selectWorkspace(workspaceID)
        #expect(action.requiredScope == .selectWorkspace)
        let decodedAction = try CMUXSidebarXPCCodec.decodeAction(
            try CMUXSidebarXPCCodec.encodeAction(action)
        )
        #expect(decodedAction == action)

        let result = CMUXExtensionActionResult(accepted: false, message: "Not found")
        let decodedResult = try CMUXSidebarXPCCodec.decodeActionResult(
            try CMUXSidebarXPCCodec.encodeActionResult(result)
        )
        #expect(decodedResult == result)
    }

    @Test
    @MainActor
    func testSidebarHostTypedHelpersSendExpectedActions() async {
        var actions = [CMUXSidebarAction]()
        var refreshCount = 0
        let workspaceID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let url = URL(string: "https://example.com/pr/1")!
        let host = CmuxSidebarHost(
            performAction: { action, reply in
                actions.append(action)
                reply(CMUXExtensionActionResult(accepted: true))
            },
            refreshSnapshot: {
                refreshCount += 1
            }
        )

        host.refresh()
        let selectResult = await host.selectWorkspace(workspaceID)
        let closeResult = await host.closeWorkspace(workspaceID)
        let openResult = await host.openURL(url)

        #expect(refreshCount == 1)
        #expect(selectResult.accepted)
        #expect(closeResult.accepted)
        #expect(openResult.accepted)
        #expect(actions == [
            .selectWorkspace(workspaceID),
            .closeWorkspace(workspaceID),
            .openURL("https://example.com/pr/1"),
        ])
    }

    @Test
    @MainActor
    func testSidebarHostCancelsPendingAsyncAction() async {
        let cancellationBox = CancellationBox()
        let startBox = ActionStartBox()
        let workspaceID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let host = CmuxSidebarHost(
            performCancellableAction: { _, _ in
                startBox.markStarted()
                return CmuxSidebarActionCancellation {
                    cancellationBox.cancel()
                }
            }
        )

        let task = Task { @MainActor in
            await host.selectWorkspace(workspaceID)
        }
        await startBox.waitUntilStarted()
        task.cancel()
        let result = await task.value

        #expect(!result.accepted)
        #expect(result.message == "Extension action was cancelled")
        #expect(cancellationBox.didCancel)
    }

    @Test
    func testSidebarXPCCodecRejectsOversizedManifestPayload() {
        let payload = Data(repeating: 0x20, count: CMUXSidebarXPCCodec.maximumManifestPayloadBytes + 1) as NSData

        do {
            _ = try CMUXSidebarXPCCodec.decodeManifest(payload)
            Issue.record("Expected oversized manifest payload to be rejected")
        } catch {
            #expect(
                error as? CMUXExtensionValidationError == .payloadTooLarge(
                    kind: "manifest",
                    actualBytes: payload.length,
                    maximumBytes: CMUXSidebarXPCCodec.maximumManifestPayloadBytes
                )
            )
        }
    }

    @Test
    func testSidebarXPCCodecRejectsOversizedActionPayload() {
        let payload = Data(repeating: 0x20, count: CMUXSidebarXPCCodec.maximumActionPayloadBytes + 1) as NSData

        do {
            _ = try CMUXSidebarXPCCodec.decodeAction(payload)
            Issue.record("Expected oversized action payload to be rejected")
        } catch {
            #expect(
                error as? CMUXExtensionValidationError == .payloadTooLarge(
                    kind: "action",
                    actualBytes: payload.length,
                    maximumBytes: CMUXSidebarXPCCodec.maximumActionPayloadBytes
                )
            )
        }
    }

    @Test
    func testSidebarXPCCodecRejectsOversizedSnapshotOnEncodeAndDecode() {
        let oversizedTitle = String(repeating: "x", count: CMUXSidebarXPCCodec.maximumSnapshotPayloadBytes)
        let snapshot = CMUXSidebarSnapshot(
            sequence: 46,
            selectedWorkspaceID: nil,
            workspaces: [
                CMUXSidebarWorkspace(id: UUID(), title: oversizedTitle),
            ]
        )

        do {
            _ = try CMUXSidebarXPCCodec.encodeSnapshot(snapshot)
            Issue.record("Expected oversized snapshot payload to be rejected on encode")
        } catch {
            if case let CMUXExtensionValidationError.payloadTooLarge(kind, actualBytes, maximumBytes) = error {
                #expect(kind == "snapshot")
                #expect(actualBytes > maximumBytes)
                #expect(maximumBytes == CMUXSidebarXPCCodec.maximumSnapshotPayloadBytes)
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }

        let payload = Data(repeating: 0x20, count: CMUXSidebarXPCCodec.maximumSnapshotPayloadBytes + 1) as NSData
        do {
            _ = try CMUXSidebarXPCCodec.decodeSnapshot(payload)
            Issue.record("Expected oversized snapshot payload to be rejected on decode")
        } catch {
            #expect(
                error as? CMUXExtensionValidationError == .payloadTooLarge(
                    kind: "snapshot",
                    actualBytes: payload.length,
                    maximumBytes: CMUXSidebarXPCCodec.maximumSnapshotPayloadBytes
                )
            )
        }
    }

    @Test
    func testSidebarXPCCodecRejectsOversizedActionResultOnEncodeAndDecode() {
        let result = CMUXExtensionActionResult(
            accepted: false,
            message: String(repeating: "x", count: CMUXSidebarXPCCodec.maximumActionResultPayloadBytes)
        )

        do {
            _ = try CMUXSidebarXPCCodec.encodeActionResult(result)
            Issue.record("Expected oversized action result payload to be rejected on encode")
        } catch {
            if case let CMUXExtensionValidationError.payloadTooLarge(kind, actualBytes, maximumBytes) = error {
                #expect(kind == "actionResult")
                #expect(actualBytes > maximumBytes)
                #expect(maximumBytes == CMUXSidebarXPCCodec.maximumActionResultPayloadBytes)
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }

        let payload = Data(repeating: 0x20, count: CMUXSidebarXPCCodec.maximumActionResultPayloadBytes + 1) as NSData
        do {
            _ = try CMUXSidebarXPCCodec.decodeActionResult(payload)
            Issue.record("Expected oversized action result payload to be rejected on decode")
        } catch {
            #expect(
                error as? CMUXExtensionValidationError == .payloadTooLarge(
                    kind: "actionResult",
                    actualBytes: payload.length,
                    maximumBytes: CMUXSidebarXPCCodec.maximumActionResultPayloadBytes
                )
            )
        }
    }

    @Test
    func testManifestValidationRejectsUnsupportedAPIVersion() {
        let manifest = CMUXExtensionManifest(
            id: "dev.example.sidebar",
            displayName: "Example Sidebar",
            minimumAPIVersion: CMUXExtensionAPIVersion(major: 1, minor: 1)
        )

        do {
            try validateSidebarManifest(manifest)
            Issue.record("Expected unsupported API version error")
        } catch {
            #expect(
                error as? CMUXExtensionValidationError == .unsupportedAPIVersion(
                    requested: CMUXExtensionAPIVersion(major: 1, minor: 1),
                    supported: .sidebarV1
                )
            )
        }
    }
}

private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var didCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func cancel() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class ActionStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func markStarted() {
        lock.lock()
        started = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
