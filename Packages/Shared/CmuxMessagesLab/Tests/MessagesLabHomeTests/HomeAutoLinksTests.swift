import Foundation
import Testing
@testable import MessagesLabHome

/// Home links everything an agent names that the app can open (Lawrence 2026-10-19): a subagent
/// link inside bold or a heading, a bare path, a bare cmux id; a refused scheme stays text.
@Suite(.serialized) struct HomeAutoLinksTests {
    init() { HomeMarkdownPolicy.install() }

    static let a81 = "cmux://chief/0123abcd/session/s-81"

    /// The (shown text, link) pairs of `markdown` rendered.
    func links(_ markdown: String) -> [(String, String)] {
        let (text, runs) = HomeMarkdown.render(markdown)
        let ns = text as NSString
        return runs.compactMap { run in run.link.map { (ns.substring(with: NSRange(location: run.start, length: run.length)), $0) } }
    }

    @Test func aSubagentIdInsideBoldIsALink() {
        let found = links("- **[a81](\(Self.a81)): focus after dropping a file.** Next.")
        #expect(found.count == 1)
        #expect(found.first?.0 == "a81")
        #expect(found.first?.1 == Self.a81)
    }

    @Test func aSubagentIdInsideAHeadingIsALink() {
        for markdown in ["## [a81](\(Self.a81)) status", "### **[a81](\(Self.a81))**"] {
            let found = links(markdown)
            #expect(found.map(\.0) == ["a81"], "\(markdown)")
            #expect(found.map(\.1) == [Self.a81], "\(markdown)")
        }
    }

    @Test func aBarePathIsAPathLink() throws {
        let found = links("Plan in /Users/me/fun/plan.md, and ~/notes/a.md.")
        #expect(found.map(\.0) == ["/Users/me/fun/plan.md", "~/notes/a.md"])
        #expect(found.first?.1 == "file:///Users/me/fun/plan.md")
        let home = try #require(found.last?.1).removingPercentEncoding
        #expect(home == "file://" + NSHomeDirectory() + "/notes/a.md")
        #expect(found.allSatisfy { URL(string: $0.1)?.isHomePathLink == true })
    }

    @Test func aPathInBoldACodeSpanOrALinkDestinationIsALink() {
        #expect(links("**/tmp/cmux-x/REPORT.md**").map(\.1) == ["file:///tmp/cmux-x/REPORT.md"])
        #expect(links("see `/Users/me/a.md` now").map(\.1) == ["file:///Users/me/a.md"])
        #expect(links("[the plan](/Users/me/My Plan.md)").map(\.1) == ["file:///Users/me/My%20Plan.md"])
    }

    @Test func aBareCmuxIdIsItsAppLink() {
        let ws = "ws_" + String(repeating: "a", count: 32)
        let found = links("Workspace \(ws) and cmux://tab/tab_\(String(repeating: "b", count: 32)).")
        #expect(found.map(\.1) == ["cmux://workspace/\(ws)", "cmux://tab/tab_\(String(repeating: "b", count: 32))"])
    }

    @Test func textThatIsNoPathStaysText() {
        #expect(links("and/or 10/19 /status https://x.com/a/b").isEmpty)
        #expect(links("foo_ws_\(String(repeating: "a", count: 32))").isEmpty)
        #expect(links("`a/b` /etcetera/x").isEmpty)
    }

    @Test func refusedSchemesNeverLink() {
        #expect(links("[x](javascript:alert(1)) [y](data:text/html,hi) [z](file://evil.com/etc/passwd)").isEmpty)
        #expect(URL(string: "file://evil.com/x")?.isHomePathLink == false)
        #expect(URL(string: "file:///x?q=1")?.isHomePathLink == false)
    }
}
