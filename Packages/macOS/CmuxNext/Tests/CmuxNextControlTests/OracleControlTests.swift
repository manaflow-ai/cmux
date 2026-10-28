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

    /// A facet that hashes a path field after the request's `paths` are rewritten (the history facet's title).
    private struct PathTitle: OracleFacetProvider {
        var facet: OracleFacet { .history }
        var capture: OracleFacetCapture { capturing(paths: .unchanged) }
        func capturing(paths: OraclePaths) -> OracleFacetCapture {
            .mainActor { () throws(OracleFacetError) -> OracleValue in .string(paths.hash("/Users/me/.cache/o/1/case")) }
        }
    }

    /// The runner names the case root and home as it gives them to normalize.py: a root inside the home is `$ROOT`.
    @Test func theRequestsPathsAreRewrittenBeforeTheHash() async throws {
        let router = router(OracleFacets([PathTitle()]))
        let paths: JSONValue = ["root": ["/Users/me/.cache/o/1"], "home": ["/Users/me"]]
        let reply = try await snapshot(router, ["facets": ["history"], "paths": paths]).get()
        #expect(reply == ["history": .string(OracleValue.sha256("$ROOT/case"))])
        let plain = try await snapshot(router, ["facets": ["history"]]).get()
        #expect(plain == ["history": .string(OracleValue.sha256("/Users/me/.cache/o/1/case"))])
    }

    @Test func pathsNormalizeWouldRefuseAreInvalidParams() async {
        for paths: JSONValue in [["root": ["/"]], ["root": ["/a"], "home": ["/a"]], ["root": "/a"], ["web": ["http://x"]], "/a"] {
            let reply = await snapshot(router(OracleFacets([PathTitle()])), ["facets": ["history"], "paths": paths])
            #expect(failure(reply)?.code == "invalid_params", "\(paths)")
        }
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
