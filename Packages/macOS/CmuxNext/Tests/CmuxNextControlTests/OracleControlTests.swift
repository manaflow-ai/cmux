#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextControl
import CmuxNextOracle
import CmuxNextSettings
import Testing

/// `debug.oracle.snapshot`: a DEV router lists every facet with its task and answers the
/// facets a case names, not-comparable when the build has no provider; the main-actor and background
/// facets answer in one reply; a typo is `invalid_params`, a failing provider `internal_error` naming its
/// facet; a Release router lists no oracle method and answers `not_allowed`, not `method_not_found`. Run: `swift test --filter OracleControlTests`.
@MainActor @Suite(.serialized) struct OracleControlTests {
    private func router(_ facets: OracleFacets, allowsDebug: Bool = true) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: allowsDebug))
        router.register(OracleControl(facets: facets).methods)
        return router
    }

    private func snapshot(_ router: ControlRouter, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: OracleControl.snapshot, params: params))
    }

    private func failure(_ result: Result<JSONValue, ControlError>) -> ControlError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test func theListNamesEveryFacetAndAMissingProviderIsNotComparable() async throws {
        let router = router(OracleFacets([]))
        let list = try await snapshot(router, ["list": true]).get()
        let expected: [JSONValue] = OracleFacet.allCases.map { facet -> JSONValue in
            ["facet": .string(facet.rawValue), "provided": false, "task": .string(facet.task)]
        }
        #expect(list == .array(expected))
        let reply = try await snapshot(router, ["facets": ["overlays"]]).get()
        #expect(reply == [
            "overlays": ["status": "not-comparable", "reason": "no provider for overlays in this build", "task": "p15-oracle-038"],
        ])
    }

    @Test func mainActorAndBackgroundFacetsAnswer() async throws {
        let main = OracleFacets([OracleFacetSource(.overlays, .mainActor { () throws(OracleFacetError) -> OracleValue in ["count": 1] })])
        #expect(try await snapshot(router(main), ["facets": ["overlays"]]).get() == ["overlays": ["count": 1]])
        let background = OracleFacets([
            OracleFacetSource(.overlays, .background { () async throws(OracleFacetError) -> OracleValue in ["list": []] }),
        ])
        #expect(try await snapshot(router(background), ["facets": ["overlays"]]).get() == ["overlays": ["list": []]])
    }

    @Test func anUnknownFacetOrANonListIsInvalidParams() async {
        let typo = await snapshot(router(OracleFacets([])), ["facets": ["overlays", "overlay"]])
        #expect(failure(typo)?.code == "invalid_params")
        let notAList = await snapshot(router(OracleFacets([])), ["facets": "overlays"])
        #expect(failure(notAList)?.code == "invalid_params")
    }

    @Test func aFailingProviderIsAnInternalErrorNamingItsFacet() async {
        let facets = OracleFacets([
            OracleFacetSource(.overlays, .background { () async throws(OracleFacetError) -> OracleValue in
                throw OracleFacetError("owners gone")
            }),
        ])
        let result = await snapshot(router(facets), ["facets": ["overlays"]])
        #expect(failure(result)?.code == "internal_error")
        #expect(failure(result)?.data == ["facet": "overlays"])
    }

    @Test func aReleaseRouterRefusesTheOracle() async {
        let router = router(OracleFacets([]), allowsDebug: false)
        #expect(router.method(named: OracleControl.snapshot) == nil)
        #expect(!router.methodNames.contains(where: { $0.hasPrefix("debug.oracle.") }))
        let result = await snapshot(router, ["list": true])
        #expect(failure(result)?.code == "not_allowed")
        #expect(failure(result)?.data == ["method": .string(OracleControl.snapshot)])
        // A later oracle method this build does not have is refused the same way, not reported as missing.
        let later = await router.handle(ControlRequest(id: "2", method: "debug.oracle.events", params: [:]))
        #expect(failure(later)?.code == "not_allowed")
        // Other debug names keep method_not_found: scripts read it as "no hooks in this build".
        let other = await router.handle(ControlRequest(id: "3", method: "debug.damage", params: [:]))
        #expect(failure(other)?.code == "method_not_found")
    }

    @Test func aDevRouterReportsAnUnknownOracleMethodAsNotFound() async {
        let result = await router(OracleFacets([])).handle(ControlRequest(id: "1", method: "debug.oracle.nope", params: [:]))
        #expect(failure(result)?.code == "method_not_found")
    }
}
#endif
