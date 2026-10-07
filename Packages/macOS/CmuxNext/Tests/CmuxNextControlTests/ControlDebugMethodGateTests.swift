import CmuxNextControl
import Testing

/// cx-9ad: a release build serves no `debug.*` socket method. The router of
/// a release configuration drops every `debug.*` registration, built-ins
/// (`debug.hangs`, `debug.queue`) and app methods alike; DEBUG builds keep them.
@Suite struct ControlDebugMethodGateTests {
    static func router(allowsDebug: Bool) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: allowsDebug))
        router.register([
            .snapshot("debug.home") { _ in .null },
            .snapshot("debug.focus") { _ in .null },
            .snapshot("resources") { _ in .null },
        ])
        return router
    }

    @Test func aReleaseRouterRegistersNoDebugMethod() {
        let router = Self.router(allowsDebug: false)
        let names = router.methodNames
        #expect(!names.isEmpty)
        #expect(names.filter(ControlRouter.isDebugMethod).isEmpty, "release serves \(names.filter(ControlRouter.isDebugMethod))")
        #expect(router.method(named: "resources") != nil, "other methods stay")
        #expect(router.method(named: "system.identify") != nil)
    }

    @Test func aDebugRouterKeepsItsDebugMethods() {
        let router = Self.router(allowsDebug: true)
        for name in ["debug.home", "debug.focus", "debug.hangs", "debug.queue"] {
            #expect(router.method(named: name) != nil, "\(name)")
        }
    }

    @Test func theDefaultFollowsTheBuildConfiguration() {
        #if DEBUG
        #expect(ControlRouter.Configuration().allowsDebugMethods)
        #else
        #expect(!ControlRouter.Configuration().allowsDebugMethods)
        #endif
    }
}
