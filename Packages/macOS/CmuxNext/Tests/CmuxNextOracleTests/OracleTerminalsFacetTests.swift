#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Foundation
import Testing

/// The `terminals` facet: the host's terminals listed in the snapshot's main-actor turn, then every
/// screen read off the main actor; the title and the last 24 rows go in only through the injected hash, after the
/// run's paths are rewritten, so two runs under different case roots hash the same.
/// Run: `swift test --filter OracleTerminalsFacetTests`.
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

    private func makeFacet(rewrite: OracleTerminalsFacet.PathRewrite = .init(root: [], home: []), changes: OracleFacetChanges? = nil,
                       _ terminals: @escaping @MainActor @Sendable () -> [OracleTerminalsFacet.Terminal]) -> OracleTerminalsFacet {
        OracleTerminalsFacet(rewrite: rewrite, hash: Self.hash, changes: changes, terminals: terminals)
    }

    private func snapshot(_ facet: OracleTerminalsFacet) async throws -> OracleValue? {
        try await OracleFacets([facet]).beginCapture([.terminals]).finish()["terminals"]
    }

    private func list(_ facet: OracleTerminalsFacet) async throws -> [OracleValue] {
        let value = try await snapshot(facet)
        guard case .array(let list)? = value?["list"] else {
            Issue.record("terminals has no list: \(String(describing: value))")
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
        #expect(OracleTerminalsFacet.PathRewrite(rootVariable: nil, home: nil).apply("/Users/me") == "/Users/me")
        #expect(OracleTerminalsFacet.PathRewrite.rootVariable == "CMUX_NEXT_ORACLE_ROOT", "the app strips inherited CMUX* but CMUX_NEXT_*")
    }

    /// The environment the app driver exports and normalize.py's `--root`/`--home` give the same token for the same
    /// path (schemas/oracle/fixtures/path-rewrite.json; normalize.py --selftest checks the Python side).
    @Test func theLaunchEnvironmentRewritesAsNormalizeDoes() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appending(path: "schemas/oracle/fixtures/path-rewrite.json"))
        let fixture = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let environment = try #require(fixture["environment"] as? [String: String])
        let cases = try #require(fixture["cases"] as? [[String: String]])
        try #require(!cases.isEmpty)
        let rewrite = OracleTerminalsFacet.PathRewrite(rootVariable: environment[OracleTerminalsFacet.PathRewrite.rootVariable],
                                                       home: environment["HOME"])
        #expect(rewrite.rewritesRoot)
        for row in cases {
            #expect(rewrite.apply(row["text"] ?? "") == row["expected"], "\(row)")
        }
    }

    @Test func theHashTakesTheLast24RowsOfTheScreen() {
        let rows = (1...30).map { "row \($0)" }
        #expect(OracleTerminalsFacet.lastRows(of: rows.joined(separator: "\n")) == rows.suffix(24).joined(separator: "\n"))
        #expect(OracleTerminalsFacet.lastRows(of: "a\nb") == "a\nb")
    }

    /// The acceptance: the screen is read off the main thread, never in the snapshot's main-actor turn.
    @Test func theScreensAreReadOffTheMainThreadAndHashedAfterTheRewrite() async throws {
        let (reads, read) = AsyncStream<Bool>.makeStream()
        let facet = makeFacet(rewrite: .init(root: ["/tmp/o/case"], home: [])) {
            [Self.terminal("term_a", title: "vim /tmp/o/case/notes") {
                read.yield(Self.onMainThread())
                return "$ ls\n/tmp/o/case/work"
            }]
        }
        #expect(facet.facet == .terminals)
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

    /// The list is the model of the snapshot's main-actor turn (with `tabs` and `layout`): a terminal closed between
    /// `beginCapture` and `finish` is still in it, and no screen is read in the turn.
    @Test func theListIsReadInTheSnapshotsMainActorTurn() async throws {
        let model = Model()
        let (reads, read) = AsyncStream<String>.makeStream()
        let facet = makeFacet {
            model.ids.map { id in Self.terminal(id) { read.yield(id); return "" } }
        }
        let capture = try OracleFacets([facet]).beginCapture([.terminals])
        #expect(capture.completed == nil)
        model.ids = []
        let value = try await capture.finish()["terminals"]
        read.finish()
        var screens: [String] = []
        for await id in reads { screens.append(id) }
        guard case .array(let items)? = value?["list"] else {
            Issue.record("terminals has no list: \(String(describing: value))")
            return
        }
        #expect(items.map { $0["terminal"] } == [.some("term_a")])
        #expect(screens == ["term_a"])
    }

    @Test func anEndedTerminalIsDeadWithItsExitCodeAndAViewlessOneDetached() async throws {
        let facet = makeFacet {
            [Self.terminal("term_a", ended: true, exitCode: 3) { "" }, Self.terminal("term_b", attach: nil) { "" }]
        }
        let list = try await list(facet)
        #expect(list.map { $0["attach"] } == [.some("dead"), .some("detached")])
        #expect(list.map { $0["exitCode"] } == [.some(3), .some(.null)])
    }

    /// Launched without the case root, a screen that shows one is not hashed raw: the facet is not comparable.
    @Test func anUnrewrittenCaseRootMakesTheFacetNotComparable() async throws {
        let facet = makeFacet(rewrite: .init(rootVariable: nil, home: "/Users/me")) {
            [Self.terminal("term_a", title: "zsh") { "u@h:/private/tmp/o/ab12cd/ef34gh/work$ " }]
        }
        let value = try await snapshot(facet)
        #expect(value?["status"] == "not-comparable")
        #expect(value?["task"] == "p15-oracle-200")
        // No case root on screen: comparable without the variable (a manual run).
        let plain = makeFacet(rewrite: .init(rootVariable: nil, home: nil)) { [Self.terminal("term_a") { "$ ls" }] }
        #expect(try await list(plain).count == 1)
    }

    /// The host's change signal is the facet's: `debug.oracle.wait_for` can wait on it; without one it cannot.
    @Test func theFacetCanBeWaitedOnOnlyWithTheHostsChangeSignal() {
        let changes: OracleFacetChanges = { AsyncStream { $0.finish() } }
        #expect(OracleFacets([makeFacet(changes: changes) { [] }]).signalsChanges(.terminals))
        #expect(!OracleFacets([makeFacet { [] }]).signalsChanges(.terminals))
    }

    /// A screen the daemon does not answer fails the snapshot: a broken read is never recorded as a value.
    @Test func aFailedScreenReadFailsTheSnapshot() async throws {
        struct Refused: Error {}
        let facet = makeFacet { [Self.terminal("term_a") { throw Refused() }] }
        let capture = try OracleFacets([facet]).beginCapture([.terminals])
        do throws(OracleSnapshotError) {
            _ = try await capture.finish()
            Issue.record("the snapshot passed a failed screen read")
        } catch {
            #expect(error.facet == .terminals)
        }
    }

    /// A main-actor model the facet lists from.
    @MainActor final class Model {
        var ids = ["term_a"]
    }
}
#endif
