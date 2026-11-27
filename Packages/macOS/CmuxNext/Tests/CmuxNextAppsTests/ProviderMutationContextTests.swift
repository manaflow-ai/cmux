import CmuxNextApps
import Testing

/// Executes the routed-call adapter and its owner handler without launching an app.
struct ProviderMutationContextTests {
    private let stamp: AppJSON = [
        "kind": "app", "id": "cmux/agents", "host": "selected-owner", "version": "1.0.0",
        "on_behalf_of": ["kind": "user", "id": "user_local"],
    ]

    @Test func mutationKeyAndActorReachTheOwnerWithoutReplacement() async throws {
        let key = "app:cmux/agents:intent-'\u{03c0}'"
        let params: AppJSON = ["machine": "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                              "idempotency_key": "params-are-not-the-envelope-key", "actor": "params-stay-params"]
        let call = try #require(RoutedAppCall([
            "request_id": 42, "app": "cmux/agents", "op": "workspace.run", "params": params,
            "origin": "user", "idempotency_key": .string(key), "actor": stamp,
        ]))
        let answer = await call.answer(with: AppHostCapabilities([Owner()]))
        #expect(answer.ok)
        #expect(answer.body == ["value": [
            "app": "cmux/agents", "origin": "user", "params": params,
            "idempotency_key": .string(key), "actor": stamp,
        ]])
    }

    @Test func anActorStampNeverUpgradesScriptOrigin() async throws {
        let call = try #require(RoutedAppCall([
            "request_id": 43, "app": "cmux/agents", "op": "workspace.run", "params": [:],
            "origin": "script", "idempotency_key": "app:cmux/agents:script", "actor": stamp,
        ]))
        let answer = await call.answer(with: AppHostCapabilities([Owner()]))
        #expect(answer.ok)
        #expect(answer.body["value"]?["origin"] == "script")
        #expect(answer.body["value"]?["actor"] == stamp)
    }

    @Test func legacyReadsKeepAbsentContextAndTheirOriginalParams() async throws {
        let params: AppJSON = ["machine": "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
        let call = try #require(RoutedAppCall([
            "request_id": 44, "app": "cmux/agents", "op": "workspace.list", "params": params,
        ]))
        let answer = await call.answer(with: AppHostCapabilities([Owner()]))
        #expect(answer.ok)
        #expect(answer.body == ["value": ["app": "cmux/agents", "origin": "script", "params": params,
                                          "idempotency_key": .null, "actor": .null]])
    }

    @Test func explicitNullContextKeepsLegacyReadCompatibility() async throws {
        let call = try #require(RoutedAppCall([
            "request_id": 45, "app": "cmux/agents", "op": "workspace.list",
            "idempotency_key": .null, "actor": .null,
        ]))
        let answer = await call.answer(with: AppHostCapabilities([Owner()]))
        #expect(answer.ok)
        #expect(answer.body["value"]?["idempotency_key"] == .null)
        #expect(answer.body["value"]?["actor"] == .null)
    }

    @Test(arguments: [AppJSON.string(""), .number(42), .bool(true), .array([]), .object([:])])
    func malformedMutationKeysAreNotSilentlyDiscarded(value: AppJSON) {
        #expect(RoutedAppCall([
            "request_id": 46, "app": "cmux/agents", "op": "workspace.run",
            "idempotency_key": value, "actor": stamp,
        ]) == nil)
    }

    @Test(arguments: [AppJSON.string("user"), .number(42), .bool(true), .array([])])
    func malformedActorMetadataIsNotSilentlyDiscarded(value: AppJSON) {
        #expect(RoutedAppCall([
            "request_id": 47, "app": "cmux/agents", "op": "workspace.run",
            "idempotency_key": "app:cmux/agents:key", "actor": value,
        ]) == nil)
    }

    private struct Owner: AppHostCapabilityHandler {
        let families: Set<String> = ["workspace"]

        func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
            ["app": .string(request.app), "origin": .string(request.origin), "params": request.params,
             "idempotency_key": request.idempotencyKey.map(AppJSON.string) ?? .null,
             "actor": request.actor ?? .null]
        }
    }
}
