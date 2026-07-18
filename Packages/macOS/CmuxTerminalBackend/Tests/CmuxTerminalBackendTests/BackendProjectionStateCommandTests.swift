@testable import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Daemon-retained projection-state commands")
struct BackendProjectionStateCommandTests {
    @Test("claim, replace, list, and explicit release preserve exact fences")
    func completeWireContract() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let logicalPresentationID = try #require(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let claimID = try #require(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        )
        let processID = try #require(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")
        )
        let workspaceID = WorkspaceID(rawValue: try #require(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        ))
        let screenID = ScreenID(rawValue: try #require(
            UUID(uuidString: "55555555-5555-4555-8555-555555555555")
        ))

        let claimTask = Task {
            try await client.claimProjectionState(
                logicalPresentationID: logicalPresentationID
            )
        }
        let claimRequest = try request(await transport.nextSent())
        #expect(claimRequest["cmd"] as? String == "claim-projection-state")
        #expect(
            claimRequest["logical_presentation_id"] as? String
                == logicalPresentationID.uuidString.lowercased()
        )
        await transport.enqueue(try response(
            to: claimRequest,
            data: statePayload(
                logicalPresentationID: logicalPresentationID,
                generation: 7,
                claimID: claimID,
                processID: processID,
                workspaces: []
            )
        ))
        let claim = try await claimTask.value
        #expect(claim.claimID == claimID)
        #expect(claim.generation == 7)

        let workspace = BackendProjectionWorkspaceState(
            workspaceID: workspaceID,
            selectedScreenID: screenID
        )
        let updateTask = Task {
            try await client.updateProjectionState(
                logicalPresentationID: logicalPresentationID,
                claimID: claimID,
                expectedGeneration: 7,
                workspaces: [workspace]
            )
        }
        let updateRequest = try request(await transport.nextSent())
        #expect(updateRequest["cmd"] as? String == "update-projection-state")
        #expect(try uint64(updateRequest, "expected_generation") == 7)
        #expect(updateRequest["claim_id"] as? String == claimID.uuidString.lowercased())
        let wireWorkspaces = try #require(updateRequest["workspaces"] as? [[String: Any]])
        #expect(wireWorkspaces.count == 1)
        #expect(wireWorkspaces[0]["workspace_uuid"] as? String == workspaceID.description)
        #expect(wireWorkspaces[0]["selected_screen_uuid"] as? String == screenID.description)
        await transport.enqueue(try response(
            to: updateRequest,
            data: statePayload(
                logicalPresentationID: logicalPresentationID,
                generation: 8,
                claimID: claimID,
                processID: processID,
                workspaces: [[
                    "workspace_uuid": workspaceID.description,
                    "selected_screen_uuid": screenID.description,
                ]]
            )
        ))
        #expect(try await updateTask.value.workspaces == [workspace])

        let listTask = Task { try await client.listProjectionStates() }
        let listRequest = try request(await transport.nextSent())
        #expect(listRequest["cmd"] as? String == "list-projection-states")
        await transport.enqueue(try response(
            to: listRequest,
            data: [statePayload(
                logicalPresentationID: logicalPresentationID,
                generation: 8,
                claimID: claimID,
                processID: processID,
                workspaces: [[
                    "workspace_uuid": workspaceID.description,
                    "selected_screen_uuid": screenID.description,
                ]]
            )]
        ))
        #expect(try await listTask.value.count == 1)

        let releaseTask = Task {
            try await client.releaseProjectionState(
                logicalPresentationID: logicalPresentationID,
                claimID: claimID,
                expectedGeneration: 8
            )
        }
        let releaseRequest = try request(await transport.nextSent())
        #expect(releaseRequest["cmd"] as? String == "release-projection-state")
        #expect(try uint64(releaseRequest, "expected_generation") == 8)
        await transport.enqueue(try response(to: releaseRequest, data: [:]))
        try await releaseTask.value
        await client.close()
    }
}

private func statePayload(
    logicalPresentationID: UUID,
    generation: UInt64,
    claimID: UUID?,
    processID: UUID?,
    workspaces: [[String: Any]]
) -> [String: Any] {
    [
        "logical_presentation_id": logicalPresentationID.uuidString,
        "generation": generation,
        "claim_id": claimID?.uuidString as Any,
        "claimed_process_instance_uuid": processID?.uuidString as Any,
        "workspaces": workspaces,
    ]
}

private func request(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func response(to request: [String: Any], data: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "id": try uint64(request, "id"),
        "ok": true,
        "data": data,
    ])
}

private func uint64(_ object: [String: Any], _ key: String) throws -> UInt64 {
    try #require(object[key] as? NSNumber).uint64Value
}
