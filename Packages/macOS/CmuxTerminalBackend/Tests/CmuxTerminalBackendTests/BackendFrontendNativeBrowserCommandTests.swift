@testable import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Frontend-native browser commands")
struct BackendFrontendNativeBrowserCommandTests {
    @Test("claim and source update preserve the private owner fence")
    func privateRuntimeWireContract() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()

        let surfaceID = SurfaceID(rawValue: UUID())
        let daemonID = DaemonInstanceID(rawValue: UUID())
        let sessionID = SessionID(rawValue: UUID())
        let claimRequestID = UUID()
        let seedURL = try #require(URL(string: "https://example.invalid/private?token=seed"))

        let claimTask = Task {
            try await client.claimFrontendNativeBrowser(
                surfaceID: surfaceID,
                requestID: claimRequestID,
                sourceURL: seedURL
            )
        }
        let claimRequest = try frontendBrowserRequest(await transport.nextSent())
        #expect(claimRequest["cmd"] as? String == "claim-frontend-native-browser")
        #expect(claimRequest["surface_uuid"] as? String == surfaceID.description)
        #expect(claimRequest["request_id"] as? String == claimRequestID.uuidString.lowercased())
        #expect(claimRequest["source_url"] as? String == seedURL.absoluteString)
        await transport.enqueue(try frontendBrowserResponse(
            to: claimRequest,
            data: [
                "request_id": claimRequestID.uuidString,
                "daemon_instance_id": daemonID.description,
                "session_id": sessionID.description,
                "surface_uuid": surfaceID.description,
                "owner_generation": 4,
                "source_url": seedURL.absoluteString,
                "replayed": false,
            ]
        ))
        let claim = try await claimTask.value
        #expect(claim.authority == BackendAuthority(
            daemonInstanceID: daemonID,
            sessionID: sessionID
        ))
        #expect(claim.sourceURL == seedURL)
        #expect(claim.ownerGeneration == 4)

        let updateRequestID = UUID()
        let updatedURL = try #require(URL(string: "https://example.invalid/private?token=updated"))
        let updateTask = Task {
            try await client.updateFrontendNativeBrowserSource(
                surfaceID: surfaceID,
                ownerGeneration: claim.ownerGeneration,
                requestID: updateRequestID,
                sourceURL: updatedURL
            )
        }
        let updateRequest = try frontendBrowserRequest(await transport.nextSent())
        #expect(
            updateRequest["cmd"] as? String
                == "update-frontend-native-browser-source"
        )
        #expect(try frontendBrowserUInt64(updateRequest, "owner_generation") == 4)
        #expect(updateRequest["source_url"] as? String == updatedURL.absoluteString)
        await transport.enqueue(try frontendBrowserResponse(
            to: updateRequest,
            data: [
                "request_id": updateRequestID.uuidString,
                "daemon_instance_id": daemonID.description,
                "session_id": sessionID.description,
                "surface_uuid": surfaceID.description,
                "owner_generation": 4,
                "replayed": false,
            ]
        ))
        let update = try await updateTask.value
        #expect(update.surfaceID == surfaceID)
        #expect(update.ownerGeneration == claim.ownerGeneration)
        await client.close()
    }

    @Test("canonical create and close use native transport and stable surface identity")
    func canonicalMutationWireContract() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()

        let daemonID = DaemonInstanceID(rawValue: UUID())
        let sessionID = SessionID(rawValue: UUID())
        let connectionID = UUID()
        let leaseID = UUID()
        let lease = try #require(BackendTopologyMutationLease(
            connectionID: connectionID,
            leaseID: leaseID,
            generation: 3
        ))
        let workspaceID = WorkspaceID(rawValue: UUID())
        let screenID = ScreenID(rawValue: UUID())
        let paneID = PaneID(rawValue: UUID())
        let surfaceID = SurfaceID(rawValue: UUID())
        let createRequestID = UUID()
        let url = try #require(URL(string: "https://example.invalid/private"))
        let authority = BackendAuthority(daemonInstanceID: daemonID, sessionID: sessionID)
        let createExpectation = BackendTopologyMutationExpectation(
            requestID: createRequestID,
            authority: authority,
            revision: 8,
            topologyLease: lease
        )

        let createTask = Task {
            try await client.canonicalNewBrowserWorkspace(
                expectation: createExpectation,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                url: url
            )
        }
        let createRequest = try frontendBrowserRequest(await transport.nextSent())
        #expect(createRequest["cmd"] as? String == "canonical-new-browser-workspace")
        #expect(createRequest["transport"] as? String == "frontend-native-v1")
        #expect(createRequest["url"] as? String == url.absoluteString)
        await transport.enqueue(try frontendBrowserResponse(
            to: createRequest,
            data: frontendBrowserPlacement(
                requestID: createRequestID,
                daemonID: daemonID,
                sessionID: sessionID,
                workspaceID: workspaceID,
                screenID: screenID,
                paneID: paneID,
                surfaceID: surfaceID,
                baseRevision: 8,
                revision: 9
            )
        ))
        #expect(try await createTask.value.surfaceID == surfaceID)

        let closeRequestID = UUID()
        let closeExpectation = BackendTopologyMutationExpectation(
            requestID: closeRequestID,
            authority: authority,
            revision: 9,
            topologyLease: lease
        )
        let closeTask = Task {
            try await client.canonicalCloseSurface(
                expectation: closeExpectation,
                surfaceID: surfaceID
            )
        }
        let closeRequest = try frontendBrowserRequest(await transport.nextSent())
        #expect(closeRequest["cmd"] as? String == "canonical-close-surface")
        #expect(closeRequest["surface_uuid"] as? String == surfaceID.description)
        await transport.enqueue(try frontendBrowserResponse(
            to: closeRequest,
            data: [
                "request_id": closeRequestID.uuidString,
                "daemon_instance_id": daemonID.description,
                "session_id": sessionID.description,
                "base_revision": 9,
                "revision": 10,
                "replayed": false,
            ]
        ))
        #expect(try await closeTask.value.revision == 10)
        await client.close()
    }
}

private func frontendBrowserPlacement(
    requestID: UUID,
    daemonID: DaemonInstanceID,
    sessionID: SessionID,
    workspaceID: WorkspaceID,
    screenID: ScreenID,
    paneID: PaneID,
    surfaceID: SurfaceID,
    baseRevision: UInt64,
    revision: UInt64
) -> [String: Any] {
    [
        "request_id": requestID.uuidString,
        "daemon_instance_id": daemonID.description,
        "session_id": sessionID.description,
        "base_revision": baseRevision,
        "revision": revision,
        "replayed": false,
        "workspace": 1,
        "workspace_uuid": workspaceID.description,
        "screen": 2,
        "screen_uuid": screenID.description,
        "pane": 3,
        "pane_uuid": paneID.description,
        "surface": 4,
        "surface_uuid": surfaceID.description,
    ]
}

private func frontendBrowserRequest(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func frontendBrowserResponse(
    to request: [String: Any],
    data: [String: Any]
) throws -> Data {
    try encodedJSON([
        "id": try frontendBrowserUInt64(request, "id"),
        "ok": true,
        "data": data,
    ])
}

private func frontendBrowserUInt64(
    _ object: [String: Any],
    _ key: String
) throws -> UInt64 {
    try #require(object[key] as? NSNumber).uint64Value
}
