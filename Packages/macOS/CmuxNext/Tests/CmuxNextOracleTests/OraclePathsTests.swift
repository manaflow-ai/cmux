#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The path rewrite a capture applies before it hashes a `derive: sha256` field with `x-oracle-rewrite: path`:
/// the same rule as normalize.py's `_Rewriter` (`rewrite_only_marked_fields`,
/// `longest_prefix_wins`), so a hash matches the one normalize would make from the rewritten text.
/// Run: `swift test --filter OraclePathsTests`.
@Suite struct OraclePathsTests {
    @Test func aRootIsRewrittenOnlyAsAWholePath() throws {
        let paths = try OraclePaths(root: ["/tmp/o/ab"])
        #expect(paths.rewrite("/tmp/o/ab/x") == "$ROOT/x")
        #expect(paths.rewrite("/tmp/o/abc/x") == "/tmp/o/abc/x", "a longer name that starts with the root is kept")
        #expect(paths.rewrite("cd /tmp/o/ab && ls /tmp/o/ab") == "cd $ROOT && ls $ROOT")
        #expect(paths.rewrite("x/tmp/o/ab") == "x/tmp/o/ab", "a name before the root is not a whole path")
    }

    @Test func aRootInsideTheHomeIsRoot() throws {
        let paths = try OraclePaths(root: ["/home/u/.cache/o/1"], home: ["/home/u/"])
        #expect(paths.rewrite("/home/u/.cache/o/1/s.sock") == "$ROOT/s.sock")
        #expect(paths.rewrite("/home/u/src") == "$HOME/src")
        #expect(paths.rewrite("/home/u/.cache/o/1 and /home/u") == "$ROOT and $HOME")
    }

    @Test func everyAliasOfAPrefixIsRewritten() throws {
        let paths = try OraclePaths(root: ["/tmp/o/ab", "/private/tmp/o/ab"])
        #expect(paths.rewrite("/private/tmp/o/ab/x /tmp/o/ab/y") == "$ROOT/x $ROOT/y")
    }

    @Test func thePrefixesNormalizeRefusesAreRefused() {
        #expect(throws: OracleRequestError.self) { _ = try OraclePaths(root: ["/"]) }
        #expect(throws: OracleRequestError.self) { _ = try OraclePaths(home: [""]) }
        #expect(throws: OracleRequestError.self) { _ = try OraclePaths(root: ["/a"], home: ["/a/"]) }
    }

    @Test func theHashIsOfTheRewrittenText() throws {
        let paths = try OraclePaths(root: ["/tmp/o/ab"], home: ["/Users/me"])
        #expect(paths.hash("/tmp/o/ab/x") == OracleValue.sha256("$ROOT/x"))
        #expect(OraclePaths.unchanged.hash("/tmp/o/ab/x") == OracleValue.sha256("/tmp/o/ab/x"))
        // sha256("abc"), the FIPS 180-2 test vector.
        #expect(OracleValue.sha256("abc") == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// A list built with prefixes gives them to a provider that asks; one that does not ask captures as before.
    @MainActor @Test func theListGivesItsPathsToTheProviders() throws {
        struct Titled: OracleFacetProvider {
            var facet: OracleFacet { .history }
            var capture: OracleFacetCapture { capturing(paths: .unchanged) }
            func capturing(paths: OraclePaths) -> OracleFacetCapture {
                .mainActor { () throws(OracleFacetError) -> OracleValue in .string(paths.rewrite("/tmp/o/ab/t")) }
            }
        }
        let facets = OracleFacets([Titled()])
        #expect(try facets.beginCapture([.history]).completed == ["history": "/tmp/o/ab/t"])
        let rewriting = facets.rewriting(try OraclePaths(root: ["/tmp/o/ab"]))
        #expect(try rewriting.beginCapture([.history]).completed == ["history": "$ROOT/t"])
        #expect(try rewriting.adding([]).beginCapture([.history]).completed == ["history": "$ROOT/t"], "adding keeps the paths")
    }
}
#endif
