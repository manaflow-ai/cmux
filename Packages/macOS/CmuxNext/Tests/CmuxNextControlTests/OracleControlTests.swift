#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextControl
import CmuxNextOracle
import CmuxNextSettings
import Testing

/// `debug.oracle.snapshot` (p15-oracle-030): a DEV router lists every facet with its task and answers the
/// facets a case names, not-comparable when the build has no provider; the main-actor and background
/// facets answer in one reply; a typo is `invalid_params`, a failing provider `internal_error` naming its
/// facet; a Release router refuses the method. Run: `swift test --filter OracleControlTests`.
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
        let reply = try await snapshot(router, ["facets": ["focus", "terminals"]]).get()
        #expect(reply == [
            "focus": ["status": "not-comparable", "reason": "no provider for focus in this build", "task": "p15-oracle-034"],
            "terminals": ["status": "not-comparable", "reason": "no provider for terminals in this build", "task": "p15-oracle-044"],
        ])
    }

    @Test func mainActorAndBackgroundFacetsAnswerTogether() async throws {
        let facets = OracleFacets([
            OracleFacetSource(.windows, .mainActor { () throws(OracleFacetError) -> OracleValue in ["count": 1] }),
            OracleFacetSource(.terminals, .background { () async throws(OracleFacetError) -> OracleValue in ["list": []] }),
        ])
        let reply = try await snapshot(router(facets), ["facets": ["windows", "terminals"]]).get()
        #expect(reply == ["windows": ["count": 1], "terminals": ["list": []]])
    }

    @Test func anUnknownFacetOrANonListIsInvalidParams() async {
        let typo = await snapshot(router(OracleFacets([])), ["facets": ["focus", "fokus"]])
        #expect(failure(typo)?.code == "invalid_params")
        let notAList = await snapshot(router(OracleFacets([])), ["facets": "focus"])
        #expect(failure(notAList)?.code == "invalid_params")
    }

    @Test func aFailingProviderIsAnInternalErrorNamingItsFacet() async {
        let facets = OracleFacets([
            OracleFacetSource(.terminals, .background { () async throws(OracleFacetError) -> OracleValue in
                throw OracleFacetError("vt-state gone")
            }),
        ])
        let result = await snapshot(router(facets), ["facets": ["terminals"]])
        #expect(failure(result)?.code == "internal_error")
        #expect(failure(result)?.data == ["facet": "terminals"])
    }

    @Test func aReleaseRouterRefusesTheOracle() async {
        let router = router(OracleFacets([]), allowsDebug: false)
        #expect(router.method(named: OracleControl.snapshot) == nil)
        #expect(!router.methodNames.contains(where: { $0.hasPrefix("debug.oracle.") }))
        let result = await snapshot(router, ["list": true])
        #expect(failure(result)?.code == "method_not_found")
    }
}
#endif
