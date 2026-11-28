import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire of the requests that moved from hand-written Swift to types generated from
/// cmux-tui/spec/sdk-schema.json (`pairing-response`, `list-notifications`, `get-frontend-projection`,
/// `put-frontend-projection`, `flush-launch-snapshot`): the exact JSON line each sends, the capability
/// that gates it, and how its reply decodes. They hold the bytes the hand-written types sent: this file passes unchanged on the commit before the move.
struct SessionProjectionRequestWireTests {
    private func line(_ request: some DaemonRequest, id: UInt64 = 1) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: id))
    }

    private func envelope(_ command: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging(["id": .number(1), "cmd": .string(command)]) { $1 })
    }

    @Test func aPairingAnswerSendsTheChallengeAndTheVerdict() throws {
        #expect(try line(PairingResponseRequest(request: 7, approve: true)) ==
            envelope("pairing-response", ["request": .number(7), "approve": .bool(true)]))
        #expect(try line(PairingResponseRequest(request: 9, approve: false)) ==
            envelope("pairing-response", ["request": .number(9), "approve": .bool(false)]))
        #expect(PairingResponseRequest.requiredCapability == nil)
        let raw = String(decoding: try WireCoding.encodeRequest(PairingResponseRequest(request: 7, approve: true), id: 1), as: UTF8.self)
        #expect(raw.contains(#""cmd":"pairing-response""#) && raw.contains(#""request":7"#) && raw.contains(#""approve":true"#))
    }

    @Test func aNotificationListSendsOnlyTheLimitItWasGiven() throws {
        #expect(try line(ListNotificationsRequest()) == envelope("list-notifications", [:]))
        #expect(try line(ListNotificationsRequest(limit: 50)) == envelope("list-notifications", ["limit": .number(50)]))
        #expect(ListNotificationsRequest.requiredCapability == "notification-ack-v1")
    }

    @Test func aProjectionReadSendsItsKeyAndScope() throws {
        #expect(try line(GetFrontendProjectionRequest(frontend: "app", scope: .shared, subjectKey: "win-1")) ==
            envelope("get-frontend-projection", ["frontend": .string("app"), "scope": .string("shared"), "subject_key": .string("win-1")]))
        #expect(GetFrontendProjectionRequest.requiredCapability == nil)
    }

    @Test func aProjectionWriteSendsTheDocumentAndTheMutationKeyFlat() throws {
        let identity = MutationIdentity(origin: "app", mutationID: "m-1")
        let document = JSONValue.object(["a": .number(1)])
        #expect(try line(PutFrontendProjectionRequest(frontend: "app", scope: .personal, subjectKey: "win-1", schemaVersion: 3,
                                                       projection: document, mutation: identity)) ==
            envelope("put-frontend-projection", [
                "frontend": .string("app"), "scope": .string("personal"), "subject_key": .string("win-1"),
                "schema_version": .number(3), "projection": document,
                "origin": .string("app"), "mutation_id": .string("m-1"),
            ]))
        #expect(try line(PutFrontendProjectionRequest(frontend: "app", scope: .personal, subjectKey: "win-1", schemaVersion: 3,
                                                       projection: .null, expectedProjectionRevision: 12,
                                                       mutation: MutationIdentity(origin: "app", mutationID: "m-2", expectedRevision: 5))) ==
            envelope("put-frontend-projection", [
                "frontend": .string("app"), "scope": .string("personal"), "subject_key": .string("win-1"),
                "schema_version": .number(3), "projection": .null, "expected_projection_revision": .number(12),
                "origin": .string("app"), "mutation_id": .string("m-2"), "expected_revision": .number(5),
            ]))
        #expect(PutFrontendProjectionRequest.requiredCapability == nil)
    }

    @Test func aLaunchSnapshotFlushCarriesNoFieldsAndIsGatedOnItsCapability() throws {
        #expect(try line(FlushLaunchSnapshotRequest()) == envelope("flush-launch-snapshot", [:]))
        #expect(FlushLaunchSnapshotRequest.requiredCapability == "launch-snapshot-flush-v1")
        let line = Data(#"{"id":2,"ok":true,"data":{"flushed":true}}"#.utf8)
        #expect(try WireCoding.decodeResponse(FlushLaunchSnapshotRequest.Response.self, from: line).flushed == true)
    }
}
