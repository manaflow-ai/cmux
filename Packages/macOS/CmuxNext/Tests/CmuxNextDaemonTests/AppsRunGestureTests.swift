import Foundation
import Testing
@testable import CmuxNextDaemon

/// `apps-run` carries the invocation's own gesture token only for a user run (`apps/runs.rs`
/// answers it with the gesture a command gets as `ctx.gesture`).
struct AppsRunGestureTests {
    private func fields(_ request: AppsRunRequest) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 7)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("not an object")
            return [:]
        }
        return fields
    }

    @Test func aUserRunSendsItsGestureToken() throws {
        let request = AppsRunRequest(app: "local/x", op: "local.x.go", args: .object([:]), idempotencyKey: "k-1",
                                     origin: .user, gesture: "palette-0001")
        let sent = try fields(request)
        #expect(sent["gesture"] == .string("palette-0001"))
        #expect(sent["origin"] == .string("user"))
    }

    @Test func aScriptRunNeverDoes() throws {
        let request = AppsRunRequest(app: "local/x", op: "local.x.go", args: .object([:]), idempotencyKey: "k-2",
                                     origin: .script, gesture: "palette-0002")
        #expect(try fields(request)["gesture"] == nil)
        let plain = AppsRunRequest(app: "local/x", op: "local.x.go", args: .object([:]), idempotencyKey: "k-3", origin: .user)
        #expect(try fields(plain)["gesture"] == nil)
    }
}
