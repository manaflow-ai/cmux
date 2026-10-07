import Foundation
import Testing
@testable import CmuxMobileWire

@Suite struct GitParamsTests {
    let fixtures = Fixtures()

    private func frames(_ message: String, phase: String = "request") throws -> [JSONValue] {
        try #require(fixtures.json("fixtures/git.json")["cases"]?.arrayValue)
            .filter { ($0["phase"]?.stringValue ?? "request") == phase && $0["message"]?.stringValue == message }
            .compactMap { $0["frame"] }
    }

    @Test func statusRoundTrips() throws {
        let params = try #require(frames("git.status").first?["params"])
        #expect(try params.decode(as: GitStatusParams.self) == GitStatusParams(path: "/Users/me/src/cmux"))
        let value = try #require(frames("git.status", phase: "result").first?["value"])
        let result = try value.decode(as: GitStatusResult.self)
        #expect(result.branch == "feat-viewer" && result.ahead == 2 && !result.detached)
        #expect(try JSONValue(encoding: result) == value)
    }

    @Test func diffParamsAndResultsRoundTrip() throws {
        for params in try frames("git.diff").compactMap({ $0["params"] }) {
            let typed = try params.decode(as: GitDiffParams.self)
            #expect(typed.scope == .uncommitted)
            #expect(try JSONValue(encoding: typed) == params)
        }
        let results = try frames("git.diff", phase: "result").compactMap { $0["value"] }
        let list = try results[0].decode(as: GitDiffResult.self)
        #expect(list.files.map(\.status) == [.modified, .renamed, .added])
        #expect(list.files[1].previousPath == "docs/old-name.md")
        #expect(list.files[2].isBinary)
        let patch = try results[1].decode(as: GitDiffResult.self)
        #expect(patch.files.first?.patch?.hasPrefix("@@ -1,4 +1,6 @@") == true)
        for value in results { #expect(try JSONValue(encoding: value.decode(as: GitDiffResult.self)) == value) }
    }
}
