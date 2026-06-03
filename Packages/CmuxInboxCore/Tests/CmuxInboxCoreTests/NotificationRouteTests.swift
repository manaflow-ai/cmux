import Foundation
import Testing

@testable import CmuxInboxCore

@Suite("NotificationRoute parsing")
struct NotificationRouteTests {
    @Test("parses a nested dictionary route")
    func parsesNestedDictionary() throws {
        let userInfo: [AnyHashable: Any] = [
            "route": [
                "kind": "workspace",
                "workspaceId": "ws-123",
                "machineId": "m-9",
            ],
        ]
        let route = try #require(NotificationRoute(userInfo: userInfo))
        #expect(route.kind == .workspace)
        #expect(route.workspaceID == "ws-123")
        #expect(route.machineID == "m-9")
    }

    @Test("parses a dictionary route without a machine id")
    func parsesDictionaryWithoutMachine() throws {
        let userInfo: [AnyHashable: Any] = [
            "route": [
                "kind": "workspace",
                "workspaceId": "ws-only",
            ],
        ]
        let route = try #require(NotificationRoute(userInfo: userInfo))
        #expect(route.workspaceID == "ws-only")
        #expect(route.machineID == nil)
    }

    @Test("parses a JSON-string route")
    func parsesJSONString() throws {
        let json = #"{"kind":"workspace","workspaceId":"ws-str","machineId":"m-str"}"#
        let route = try #require(NotificationRoute(userInfo: ["route": json]))
        #expect(route.kind == .workspace)
        #expect(route.workspaceID == "ws-str")
        #expect(route.machineID == "m-str")
    }

    @Test("returns nil when no route key is present")
    func nilWithoutRouteKey() {
        #expect(NotificationRoute(userInfo: ["other": "value"]) == nil)
    }

    @Test("returns nil for an unknown route kind")
    func nilForUnknownKind() {
        let userInfo: [AnyHashable: Any] = [
            "route": [
                "kind": "galaxy",
                "workspaceId": "ws-x",
            ],
        ]
        #expect(NotificationRoute(userInfo: userInfo) == nil)
    }

    @Test("returns nil when the workspace id is missing")
    func nilWithoutWorkspaceID() {
        let userInfo: [AnyHashable: Any] = [
            "route": [
                "kind": "workspace",
            ],
        ]
        #expect(NotificationRoute(userInfo: userInfo) == nil)
    }

    @Test("returns nil for a malformed JSON-string route")
    func nilForMalformedJSON() {
        #expect(NotificationRoute(userInfo: ["route": "not json"]) == nil)
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let route = NotificationRoute(kind: .workspace, workspaceID: "ws-rt", machineID: nil)
        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(NotificationRoute.self, from: data)
        #expect(decoded == route)
    }
}
