import CmuxNextApps
import Foundation
import Testing
@testable import CmuxNextApp

/// The Mac as a provider of app op families (app-op-routing.md): a routed
/// call reaches its family's owner handler with the supervisor's origin, and
/// the answer goes back in the ABI body shapes.
@Suite struct AppsProviderTests {
    /// Echoes the request it got; `fail.*` ops refuse with details.
    private nonisolated struct EchoOps: AppHostCapabilityHandler {
        var families: Set<String> { ["echo", "fail"] }

        func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
            guard request.op.hasPrefix("echo.") else {
                throw AppHostCapabilityError(code: "echo.refused", message: "no", retryable: true, details: ["op": .string(request.op)])
            }
            return ["app": .string(request.app), "origin": .string(request.origin), "params": request.params]
        }
    }

    private func call(_ op: String, origin: String = "user") throws -> AppsProviderCall {
        try #require(AppsProviderCall(["request_id": 7, "app": "cmux/coderouter", "op": .string(op), "params": ["x": 1], "origin": .string(origin),
                                       "deadline_ms": 30000]))
    }

    @Test func aCallReachesItsFamilyWithTheSupervisorsOrigin() async throws {
        let ping = try call("echo.ping")
        let (ok, body) = await ping.answer(with: AppHostCapabilities([EchoOps()]))
        #expect(ok)
        #expect(body == ["app": "cmux/coderouter", "origin": "user", "params": ["x": 1]])
        let agent = try call("echo.ping", origin: "agent")
        let scripted = await agent.answer(with: AppHostCapabilities([EchoOps()]))
        #expect(scripted.body["origin"] == "script", "only the supervisor's `user` stamp counts as user")
    }

    @Test func aRefusalAndAnUnknownFamilyAnswerTheABIErrorBody() async throws {
        let fail = try call("fail.now")
        let refused = await fail.answer(with: AppHostCapabilities([EchoOps()]))
        #expect(!refused.ok)
        #expect(refused.body == ["code": "echo.refused", "message": "no", "retryable": true, "details": ["op": "fail.now"]])
        let fs = try call("fs.list")
        let unknown = await fs.answer(with: AppHostCapabilities([EchoOps()]))
        #expect(!unknown.ok && unknown.body["code"] == "operation.unsupported")
    }

    @Test func aRequestWithoutItsIDOrOpIsDropped() {
        #expect(AppsProviderCall(["app": "a", "op": "echo.ping"]) == nil)
        #expect(AppsProviderCall(["request_id": 1, "app": "a"]) == nil)
    }

    @Test func theHandlersFamiliesAreWhatTheMacRegisters() {
        #expect(AppHostCapabilities([EchoOps()]).families == ["echo", "fail"])
    }
}
