import CmuxNextDaemon
import Foundation
import Testing

@Suite struct CloudNativeCredentialTests {
    private let scope = String(repeating: "a", count: 64)

    private func answer(_ native: CloudCredentialNativeLink, app: String = "cmux/cloud") async -> CloudCredentialRelay.Answer {
        let scope = scope
        let relay = CloudCredentialRelay(post: { _, _, _ in throw CancellationError() }, token: { throw CancellationError() }, invalidate: {},
            session: { .init(signedIn: true, team: "team_test", scope: scope, requiresScope: true, nativeLink: native) }, allowedOps: { [] })
        return await relay.answer(.init(requestID: 1, app: app, origin: "script", op: "credential.session", params: .object([:])))
    }

    @Test(arguments: [nil, "/tmp/owned-native.sock"] as [String?])
    func aNativeSessionPublishesAnExplicitScopedBinding(socket: String?) async throws {
        let native = try #require(CloudCredentialNativeLink(scope: scope, socket: socket))
        let result = await answer(native)
        #expect(result.ok)
        #expect(result.body["native_link"]?["version"]?.doubleValue == 1)
        #expect(result.body["native_link"]?["scope"]?.stringValue == scope)
        #expect(result.body["native_link"]?["socket"] == (socket.map(JSONValue.string) ?? .null))
    }

    @Test func anotherScopeOrAppCannotReceiveTheBinding() async throws {
        let native = try #require(CloudCredentialNativeLink(scope: String(repeating: "b", count: 64), socket: "/tmp/owned-native.sock"))
        #expect(await answer(native).ok == false)
        #expect(await answer(native, app: "third-party/untrusted").ok == false)
    }

    @Test func malformedPathsAreNotNativeBindings() {
        for socket in ["relative.sock", "/tmp/../foreign.sock", "/tmp/bad\u{0}.sock", "/" + String(repeating: "a", count: 104)] {
            #expect(CloudCredentialNativeLink(scope: scope, socket: socket) == nil)
        }
        #expect(CloudCredentialNativeLink(scope: "not-a-scope", socket: nil) == nil)
    }

    @Test(arguments: [false, true])
    func startupIsBoundBeforeAndAfterTheOriginalScope(change: Bool) async {
        let world = CloudNativeCredentialWorld()
        if change { await world.changeDuringStartup() }
        let relay = CloudCredentialRelay(post: { _, _, _ in throw CancellationError() }, token: { throw CancellationError() }, invalidate: {},
            session: { await world.session() }, allowedOps: { [] }, ensureNative: { await world.ensure($0) })
        let call = AppsProviderCall(requestID: 1, app: "cmux/cloud", origin: "script", op: "credential.session",
            params: .object(["ensure_native": .bool(true), "expected_scope": .string(scope)]))
        let result = await relay.answer(call)
        #expect(result.ok == !change)
        #expect(await world.ensures == [scope])
        if !change { #expect(result.body["native_link"]?["socket"]?.stringValue == "/tmp/owned-native.sock") }
        let wrong = AppsProviderCall(requestID: 2, app: "cmux/cloud", origin: "script", op: "credential.session",
            params: .object(["ensure_native": .bool(true), "expected_scope": .string("wrong")]))
        #expect(await relay.answer(wrong).ok == false)
        #expect(await world.ensures.count == 1)
    }
}
