@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// A release router drops every `debug.*` registration except the read-only diagnostics marked
/// `servingRelease()` (`debug.memory`, p07-memory 010); a DEBUG router serves both.
@Suite struct ControlRouterReleaseDiagnosticsTests {
    private func router(allowsDebug: Bool) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                                   configuration: .init(allowsDebugMethods: allowsDebug))
        router.register([
            .async("debug.plain") { _ in .string("plain") },
            .async("debug.diagnostic") { _ in .string("diagnostic") }.servingRelease(),
        ])
        return router
    }

    @Test func releaseRouterServesOnlyTheReleaseDiagnostic() async throws {
        let router = router(allowsDebug: false)
        #expect(router.method(named: "debug.plain") == nil)
        #expect(router.method(named: "debug.diagnostic")?.servesRelease == true)
        let reply = try await router.handle(ControlRequest(id: "1", method: "debug.diagnostic", params: [:])).get()
        #expect(reply == .string("diagnostic"))
        let refused = await router.handle(ControlRequest(id: "2", method: "debug.plain", params: [:]))
        #expect(throws: ControlError.self) { try refused.get() }
    }

    @Test func debugRouterServesBoth() {
        let router = router(allowsDebug: true)
        #expect(router.methodNames.contains("debug.plain"))
        #expect(router.methodNames.contains("debug.diagnostic"))
    }

    @Test func wrappingKeepsTheReleaseMark() {
        let method = ControlMethod.async("debug.diagnostic") { _ in .null }.servingRelease()
        #expect(method.wrappingAsync { call, inner in try await inner(call) }.servesRelease)
    }
}
