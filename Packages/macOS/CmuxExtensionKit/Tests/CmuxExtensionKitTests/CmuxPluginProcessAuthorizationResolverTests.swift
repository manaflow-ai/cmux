import Testing
@testable import CmuxPluginAuthorizationCore

@Suite
struct CmuxPluginProcessAuthorizationResolverTests {
    @Test
    func resolvesDescendantsAndStopsAtMissingParents() {
        let parents: [Int32: Int32] = [200: 100, 300: 200]
        let resolver = CmuxPluginProcessAuthorizationResolver(
            parentProcessLookup: { parents[$0] }
        )

        #expect(resolver.resolve(
            processID: 300,
            authorizations: [100: .active(pluginID: "dev.example.plugin")]
        ) == CmuxPluginProcessAuthorizationResolver.Resolution(
            rootProcessID: 100,
            authorization: .active(pluginID: "dev.example.plugin")
        ))
        #expect(resolver.resolve(processID: 999, authorizations: [100: .revoked]) == nil)
    }

    @Test
    func rejectsCyclesAndInvalidProcessIdentifiers() {
        let resolver = CmuxPluginProcessAuthorizationResolver(
            parentProcessLookup: { processID in
                processID == 10 ? 11 : (processID == 11 ? 10 : nil)
            }
        )

        #expect(resolver.resolve(processID: 0, authorizations: [10: .revoked]) == nil)
        #expect(resolver.resolve(processID: 10, authorizations: [:]) == nil)
    }
}
