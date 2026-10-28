@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextSignposts
import Testing

/// `debug.capabilities`: the build's registered `debug.*` methods, emitted signposts and
/// probe launch variables, read-only and with no params, so the perf lab can tell a build that cannot measure a
/// story from a regression.
@Suite struct DebugCapabilitiesTests {
    private func makeRouter(allowsDebug: Bool = true) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                                   configuration: .init(allowsDebugMethods: allowsDebug))
        router.register([.async("debug.later") { _ in .null }])
        return router
    }

    private func strings(_ reply: JSONValue, _ key: String) -> [String] {
        (reply[key]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    @Test func listsEveryRegisteredDebugMethodSortedAndNoOtherMethod() async throws {
        let router = makeRouter()
        let reply = try await router.handle(ControlRequest(id: "1", method: "debug.capabilities", params: [:])).get()
        let methods = strings(reply, "methods")
        #expect(reply["schema"]?.stringValue == DebugCapabilities.schema)
        #expect(methods == methods.sorted())
        #expect(methods.contains("debug.capabilities"))
        #expect(methods.contains("debug.hangs"))
        #expect(methods.contains("debug.later"), "a group registered after the router was made")
        #expect(!methods.contains("system.ping"))
        #expect(Set(methods) == Set(router.methodNames.filter(ControlRouter.isDebugMethod)))
    }

    @Test func signpostsAreTheEmittedCasesWireNames() async throws {
        let reply = try await makeRouter().handle(ControlRequest(id: "1", method: "debug.capabilities", params: [:])).get()
        let signposts = strings(reply, "signposts")
        #expect(signposts == Set(DebugCapabilities.emittedSignposts.map(\.description)).sorted())
        #expect(signposts.contains("action.commit"))
        #expect(signposts.contains("key.scroll_frame"))
        #expect(!signposts.contains(SignpostName.actionPresented.description), "a reserved case has no emitter")
        #expect(strings(reply, "environment").contains("CMUX_NEXT_TYPING_PROBE"))
    }

    @Test func takesNoParamsAndChangesNothing() async throws {
        let router = makeRouter()
        let names = router.methodNames
        let generation = router.snapshots.current.generation
        let refused = await router.handle(ControlRequest(id: "1", method: "debug.capabilities", params: ["clear": true]))
        #expect(throws: ControlError.self) { try refused.get() }
        let first = try await router.handle(ControlRequest(id: "2", method: "debug.capabilities", params: [:])).get()
        let second = try await router.handle(ControlRequest(id: "3", method: "debug.capabilities", params: [:])).get()
        #expect(first == second)
        #expect(router.methodNames == names)
        #expect(router.snapshots.current.generation == generation)
    }

    @Test func aReleaseRouterDoesNotServeIt() {
        #expect(makeRouter(allowsDebug: false).method(named: "debug.capabilities") == nil)
    }

    @Test func emittedListsHaveNoDuplicates() {
        #expect(Set(DebugCapabilities.emittedSignposts).count == DebugCapabilities.emittedSignposts.count)
        #expect(Set(DebugCapabilities.probeEnvironment).count == DebugCapabilities.probeEnvironment.count)
    }
}
