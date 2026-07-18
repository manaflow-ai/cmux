@testable import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Remote tmux producer source commands")
struct BackendRemoteTmuxProducerSourceCommandTests {
    @Test("claim and update keep private connection state behind an owner generation")
    func privateProducerWireContract() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()

        let producerID = UUID()
        let daemonID = DaemonInstanceID(rawValue: UUID())
        let sessionID = SessionID(rawValue: UUID())
        let claimRequestID = UUID()
        let source = BackendRemoteTmuxProducerSource(
            destination: "agent@private.invalid",
            port: 2222,
            identityFile: "/private/id_ed25519",
            sessionName: "agents"
        )

        let claimTask = Task {
            try await client.claimRemoteTmuxProducerSource(
                producerID: producerID,
                requestID: claimRequestID,
                source: source
            )
        }
        let claimRequest = try requestObject(await transport.nextSent())
        #expect(claimRequest["cmd"] as? String == "claim-remote-tmux-producer-source")
        #expect(claimRequest["producer_id"] as? String == producerID.uuidString.lowercased())
        #expect(claimRequest["request_id"] as? String == claimRequestID.uuidString.lowercased())
        let claimSource = try #require(claimRequest["source"] as? [String: Any])
        #expect(claimSource["destination"] as? String == source.destination)
        #expect(try uint64(claimSource, "port") == 2222)
        #expect(claimSource["identity_file"] as? String == source.identityFile)
        #expect(claimSource["session_name"] as? String == source.sessionName)
        await transport.enqueue(try response(
            to: claimRequest,
            data: [
                "request_id": claimRequestID.uuidString,
                "daemon_instance_id": daemonID.description,
                "session_id": sessionID.description,
                "producer_id": producerID.uuidString,
                "owner_generation": 4,
                "source": [
                    "destination": source.destination,
                    "port": 2222,
                    "identity_file": try #require(source.identityFile),
                    "session_name": source.sessionName,
                ],
                "replayed": false,
            ]
        ))
        let claim = try await claimTask.value
        #expect(claim.authority == BackendAuthority(
            daemonInstanceID: daemonID,
            sessionID: sessionID
        ))
        #expect(claim.producerID == producerID)
        #expect(claim.source == source)
        #expect(claim.ownerGeneration == 4)

        let updateRequestID = UUID()
        let renamed = BackendRemoteTmuxProducerSource(
            destination: source.destination,
            port: source.port,
            identityFile: source.identityFile,
            sessionName: "renamed"
        )
        let updateTask = Task {
            try await client.updateRemoteTmuxProducerSource(
                producerID: producerID,
                ownerGeneration: claim.ownerGeneration,
                requestID: updateRequestID,
                source: renamed
            )
        }
        let updateRequest = try requestObject(await transport.nextSent())
        #expect(updateRequest["cmd"] as? String == "update-remote-tmux-producer-source")
        #expect(try uint64(updateRequest, "owner_generation") == 4)
        let updateSource = try #require(updateRequest["source"] as? [String: Any])
        #expect(updateSource["session_name"] as? String == "renamed")
        await transport.enqueue(try response(
            to: updateRequest,
            data: [
                "request_id": updateRequestID.uuidString,
                "daemon_instance_id": daemonID.description,
                "session_id": sessionID.description,
                "producer_id": producerID.uuidString,
                "owner_generation": 4,
                "replayed": false,
            ]
        ))
        let update = try await updateTask.value
        #expect(update.producerID == producerID)
        #expect(update.ownerGeneration == claim.ownerGeneration)

        let debug = String(reflecting: claim)
        #expect(!debug.contains(source.destination))
        #expect(!debug.contains(source.sessionName))
        #expect(!debug.contains(source.identityFile!))
        await client.close()
    }

    private func requestObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(to request: [String: Any], data: Any) throws -> Data {
        try encodedJSON([
            "id": try uint64(request, "id"),
            "ok": true,
            "data": data,
        ])
    }

    private func uint64(_ object: [String: Any], _ key: String) throws -> UInt64 {
        try #require(object[key] as? NSNumber).uint64Value
    }
}
