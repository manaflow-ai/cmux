import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Find in Directory (⇧⌘F): ripgrep over the terminal's working directory,
/// matches as a palette page. The runner is driven by a stand-in `rg`
/// script, so these need no ripgrep install.
@MainActor
struct FindInDirectoryTests {
    private static func matchLine(path: [String: String], text: String, line: Int, start: Int?) throws -> String {
        var data: [String: Any] = ["path": path, "lines": ["text": text], "line_number": line]
        data["submatches"] = start.map { [["match": ["text": "x"], "start": $0, "end": $0 + 1]] } ?? []
        let json = try JSONSerialization.data(withJSONObject: ["type": "match", "data": data])
        return String(decoding: json, as: UTF8.self)
    }

    /// A stand-in for `rg` that runs `body` with `$root` set to its last argument.
    private static func fakeRipgrep(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("rg")
        try "#!/bin/sh\nfor root; do :; done\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func parsesAMatchRelativeToTheRoot() throws {
        let line = try Self.matchLine(path: ["text": "/r/src/a.swift"], text: "  let x = 1\n", line: 12, start: 6)
        let match = try #require(RipgrepSearch.parse(line, root: "/r"))
        #expect(match == RipgrepMatch(path: "/r/src/a.swift", relativePath: "src/a.swift", line: 12, column: 7,
                                      preview: "let x = 1"))
    }

    @Test func parsesBase64PathsAndSkipsOtherMessages() throws {
        let encoded = Data("/r/b.txt".utf8).base64EncodedString()
        let line = try Self.matchLine(path: ["bytes": encoded], text: "hit", line: 1, start: nil)
        #expect(RipgrepSearch.parse(line, root: "/r/")?.relativePath == "b.txt")
        #expect(RipgrepSearch.parse(line, root: "/r/")?.column == 1)
        #expect(RipgrepSearch.parse(#"{"type":"begin","data":{"path":{"text":"/r/b.txt"}}}"#, root: "/r") == nil)
        #expect(RipgrepSearch.parse("not json", root: "/r") == nil)
    }

    @Test func theQueryFollowsTheOptionTerminator() {
        let arguments = RipgrepSearch.arguments(query: "-v", root: "/r")
        #expect(Array(arguments.suffix(3)) == ["--", "-v", "/r"])
        #expect(arguments.contains("--fixed-strings") && arguments.contains("--hidden") && arguments.contains("--json"))
        #expect(arguments.contains("!**/node_modules/**"))
    }

    @Test func findsRipgrepInKnownPlacesBeforePath() {
        let installed: Set<String> = ["/usr/local/bin/rg", "/custom/bin/rg"]
        let found = RipgrepSearch.executable(environment: ["PATH": "/custom/bin"], userName: "u", home: "/Users/u",
                                             isExecutable: installed.contains)
        #expect(found?.path == "/usr/local/bin/rg")
        let onPath = RipgrepSearch.executable(environment: ["PATH": "/a:/custom/bin"], userName: "u", home: "/Users/u",
                                              isExecutable: { $0 == "/custom/bin/rg" })
        #expect(onPath?.path == "/custom/bin/rg")
        #expect(RipgrepSearch.executable(environment: [:], userName: "u", home: "/Users/u", isExecutable: { _ in false }) == nil)
    }

    @Test func runStopsAtTheLimit() async throws {
        let rg = try Self.fakeRipgrep("""
        for n in 1 2 3; do
          printf '{"type":"match","data":{"path":{"text":"%s/f%s"},"lines":{"text":"hit"},"line_number":%s,"submatches":[]}}\\n' "$root" $n $n
        done
        """)
        let root = rg.deletingLastPathComponent().path
        let outcome = await RipgrepSearch.run(rg, query: "hit", root: root, limit: 2)
        guard case .matches(let matches, let limited) = outcome else { Issue.record("\(outcome)"); return }
        #expect(limited)
        #expect(matches.map(\.relativePath) == ["f1", "f2"])
        let all = await RipgrepSearch.run(rg, query: "hit", root: root, limit: 10)
        guard case .matches(let every, false) = all else { Issue.record("\(all)"); return }
        #expect(every.count == 3)
    }

    @Test func noMatchesIsNotAFailureButAnErrorIs() async throws {
        let none = try Self.fakeRipgrep("exit 1")
        #expect(await RipgrepSearch.run(none, query: "q", root: none.deletingLastPathComponent().path) == .matches([], limited: false))
        let broken = try Self.fakeRipgrep("echo 'rg: bad' >&2; exit 2")
        #expect(await RipgrepSearch.run(broken, query: "q", root: broken.deletingLastPathComponent().path) == .failed(status: 2))
    }

    @Test func pageRowsOpenMatchesAndExplainLimitsAndFailures() {
        let match = RipgrepMatch(path: "/r/a.swift", relativePath: "a.swift", line: 3, column: 1, preview: "hit")
        let rows = FindInDirectoryPage.items(for: .matches([match], limited: true)) { _ in }
        #expect(rows.map(\.title) == ["hit", FindInDirectoryStrings.limited(RipgrepSearch.limit)])
        #expect(rows[0].subtitle == "a.swift:3")
        #expect(rows[0].secondary.map(\.id) == ["reveal", "copyPath", "copyRelativePath", "insertPath"])
        #expect(!rows[1].isEnabled)
        let failed = FindInDirectoryPage.items(for: .failed(status: 2)) { _ in }
        #expect(failed.map(\.title) == [FindInDirectoryStrings.ripgrepExited(2)])
    }

    @Test func insertPathQuotesForTheShell() throws {
        var inserted: [String] = []
        let match = RipgrepMatch(path: "/r/it's.txt", relativePath: "it's.txt", line: 1, column: 1, preview: "hit")
        let row = try #require(FindInDirectoryPage.items(for: .matches([match], limited: false)) { inserted.append($0) }.first)
        guard case .perform(let run) = try #require(row.secondary.first { $0.id == "insertPath" }).effect else {
            Issue.record("Insert Path should close the palette and run")
            return
        }
        run()
        #expect(inserted == [#"'/r/it'\''s.txt'"#])
    }

    @Test func theActionIsBoundAndTakesTheQueryAsText() throws {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(services.registry.isBound("findInDirectory"))
        #expect(services.registry.unavailableReason(for: "findInDirectory") == nil)
        #expect(services.registry.descriptor(for: "findInDirectory")?.arguments.map(\.name) == ["text"])
    }

    @Test func refusesATerminalWithNoKnownDirectory() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        let tab = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), arguments: ["text": .string("q")])
        let refusal = services.registry.capturingRefusal { services.registry.perform("findInDirectory", invocation: invocation) }
        #expect(refusal == RefusalStrings.noWorkingDirectory)
    }
}

