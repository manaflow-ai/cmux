#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Foundation
import Testing

/// The `terminals` facet (p15-oracle-044): the host's terminals from one main-actor hop, then every screen read off
/// the main actor; the title and the last 24 rows go in only through the injected hash, after the run's paths are
/// rewritten, so two runs under different case roots hash the same. Run: `swift test --filter OracleTerminalsFacetTests`.
@MainActor
struct OracleTerminalsFacetTests {
    /// Shows the text that went through the hash, so a test sees it was rewritten and never recorded raw.
    nonisolated static func hash(_ text: String) -> String { "hashed(\(text))" }

    /// Sync, so an async closure can ask which thread it runs on.
    nonisolated static func onMainThread() -> Bool { Thread.isMainThread }

    nonisolated static func terminal(_ id: String, title: String = "zsh", ended: Bool = false, exitCode: Int? = nil,
                                     attach: OracleTerminalsFacet.Attach? = .attached,
                                     screen: @escaping @Sendable () async throws -> String) -> OracleTerminalsFacet.Terminal {
        OracleTerminalsFacet.Terminal(terminal: id, tab: "tab_" + id, cols: 80, rows: 24, title: title, cwd: "/tmp/o/case/work",
                                      ended: ended, exitCode: exitCode,
                                      attach: attach.map { state in { @Sendable () -> OracleTerminalsFacet.Attach in state } },
                                      screen: screen)
    }

    private func list(_ facet: OracleTerminalsFacet) async throws -> [OracleValue] {
        let snapshot = try await OracleFacets([facet]).beginCapture([.terminals]).finish()
        guard case .array(let list)? = snapshot["terminals"]?["list"] else {
            Issue.record("terminals has no list: \(String(describing: snapshot["terminals"]))")
            return []
        }
        return list
    }

    @Test func theRewriteReplacesWholePathsLongestFirst() {
        let rewrite = OracleTerminalsFacet.PathRewrite(root: ["/Users/me/o/ab/"], home: ["/Users/me"])
        #expect(rewrite.apply("me@mac:/Users/me/o/ab/work$ ") == "me@mac:$ROOT/work$ ")
        #expect(rewrite.apply("cd /Users/me/src && ls") == "cd $HOME/src && ls")
        // A prefix inside a longer name stays.
        #expect(rewrite.apply("/Users/mel/x /Users/me") == "/Users/mel/x $HOME")
        #expect(OracleTerminalsFacet.PathRewrite(environment: [:]).apply("/Users/me") == "/Users/me")
        // The runner names each alias of the case root a shell may report.
        let launched = OracleTerminalsFacet.PathRewrite(environment: [OracleTerminalsFacet.PathRewrite.rootVariable: "/tmp/o/ab:/private/tmp/o/ab",
                                                                      "HOME": "/Users/me"])
        #expect(launched.apply("/private/tmp/o/ab/x /tmp/o/ab/y ~ /Users/me") == "$ROOT/x $ROOT/y ~ $HOME")
    }

    @Test func theHashTakesTheLast24RowsOfTheScreen() {
        let rows = (1...30).map { "row \($0)" }
        #expect(OracleTerminalsFacet.lastRows(of: rows.joined(separator: "\n")) == rows.suffix(24).joined(separator: "\n"))
        #expect(OracleTerminalsFacet.lastRows(of: "a\nb") == "a\nb")
    }

    /// The acceptance: the screen is read off the main thread, never in the snapshot's main-actor hop.
    @Test func theScreensAreReadOffTheMainThreadAndHashedAfterTheRewrite() async throws {
        let (reads, read) = AsyncStream<Bool>.makeStream()
        let rewrite = OracleTerminalsFacet.PathRewrite(root: ["/tmp/o/case"], home: [])
        let facet = OracleTerminalsFacet(rewrite: rewrite, hash: Self.hash) {
            [Self.terminal("term_a", title: "vim /tmp/o/case/notes") {
                read.yield(Self.onMainThread())
                return "$ ls\n/tmp/o/case/work"
            }]
        }
        #expect(facet.facet == .terminals)
        #expect(try OracleFacets([facet]).beginCapture([.terminals]).completed == nil)
        let list = try await list(facet)
        read.finish()
        var onMain: [Bool] = []
        for await flag in reads { onMain.append(flag) }
        #expect(onMain == [false])
        let expected: OracleValue = [
            "terminal": "term_a", "tab": "tab_term_a", "attach": "attached", "cols": 80, "rows": 24,
            "title": "hashed(vim $ROOT/notes)", "cwd": "/tmp/o/case/work",
            "last24Sha256": "hashed($ ls\n$ROOT/work)", "exitCode": nil,
        ]
        #expect(list == [expected])
    }

    @Test func anEndedTerminalIsDeadWithItsExitCodeAndAViewlessOneDetached() async throws {
        let facet = OracleTerminalsFacet(rewrite: .init(root: [], home: []), hash: Self.hash) {
            [Self.terminal("term_a", ended: true, exitCode: 3) { "" }, Self.terminal("term_b", attach: nil) { "" }]
        }
        let list = try await list(facet)
        #expect(list.map { $0["attach"] } == [.some("dead"), .some("detached")])
        #expect(list.map { $0["exitCode"] } == [.some(3), .some(.null)])
    }

    /// A screen the daemon does not answer fails the snapshot: a broken read is never recorded as a value.
    @Test func aFailedScreenReadFailsTheSnapshot() async throws {
        struct Refused: Error {}
        let facet = OracleTerminalsFacet(rewrite: .init(root: [], home: []), hash: Self.hash) {
            [Self.terminal("term_a") { throw Refused() }]
        }
        let capture = try OracleFacets([facet]).beginCapture([.terminals])
        do throws(OracleSnapshotError) {
            _ = try await capture.finish()
            Issue.record("the snapshot passed a failed screen read")
        } catch {
            #expect(error.facet == .terminals)
        }
    }
}
#endif
