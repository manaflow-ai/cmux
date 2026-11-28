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
        #expect(links("[REPORT.md](file:///Users/me/REPORT.md)").map(\.0) == ["REPORT.md"])
        #expect(links("[the plan](/Users/me/My Plan.md)").map(\.1) == ["file:///Users/me/My%20Plan.md"])
    }

    @Test func aBareCmuxIdIsItsAppLinkWithAShortLabel() {
        let ws = "ws_" + String(repeating: "a", count: 32)
        let found = links("Workspace \(ws) here.")
        #expect(found.map(\.0) == ["ws_aaaaaaaa…"])
        #expect(found.map(\.1) == ["cmux://workspace/\(ws)"])
    }

    @Test func aBareCmuxURLIsALinkWithAShortLabel() {
        let url = "cmux://workspace/ws_9166682ee2857086e345b3aa42e54cda"
        let found = links("Open \(url).")
        #expect(found.map(\.0) == ["ws_9166682e…"])
        #expect(found.map(\.1) == [url])
    }

    /// cmux#25572: a bare GitHub pull request, issue, commit or run URL shows by its short name
    /// and opens the URL; any other GitHub page (a sign-in page) still shows as written.
    @Test func aBareGitHubURLShowsItsShortName() {
        let pr = "https://github.com/manaflow-ai/cmux/pull/25572"
        let issue = "https://github.com/manaflow-ai/cmux/issues/123#issuecomment-9"
        let commit = "https://github.com/manaflow-ai/cmux/commit/184cb2f77473f0123456789abcdef0123456789a"
        let run = "https://github.com/manaflow-ai/cmux/actions/runs/39221907733"
        let found = links("PR \(pr), issue \(issue), commit \(commit) and run \(run).")
        #expect(found.map(\.0) == ["#25572", "#123", "184cb2f", "run 39221907733"])
        #expect(found.map(\.1) == [pr, issue, commit, run])
        #expect(links("https://github.com/manaflow-ai/cmux").map(\.0) == ["https://github.com/manaflow-ai/cmux"])
    }

    @Test func aMarkdownCmuxLinkKeepsItsName() {
        let url = "cmux://workspace/ws_9166682ee2857086e345b3aa42e54cda"
        let found = links("See [Chief · tab audio toggles](\(url)).")
        #expect(found.map(\.0) == ["Chief · tab audio toggles"])
        #expect(found.map(\.1) == [url])
    }

    /// A long bare link shows a short label with no break opportunity (no space or slash),
    /// so it wraps as one unit instead of across two lines.
    @Test func aLongBareLinkWrapsAsOneUnit() {
        let long = "/Users/me/fun/cmux-worktrees/chief-links-everywhere/very/deep/REPORT.md"
        let url = "cmux://session/" + String(repeating: "c", count: 60)
        let found = links("Report \(long) and chat \(url) and tab_\(String(repeating: "d", count: 32))")
        #expect(found.map(\.0) == ["REPORT.md", String(repeating: "c", count: 12) + "…", "tab_dddddddd…"])
        for (label, _) in found {
            #expect(label.utf16.count <= 16, "\(label)")
            #expect(!label.contains(" ") && !label.contains("/"), "\(label)")
        }
        #expect(found.first?.1 == "file://" + long)
    }

    @Test func textThatIsNoPathStaysText() {
        #expect(links("and/or 10/19 /status").isEmpty)
        #expect(links("foo_ws_\(String(repeating: "a", count: 32))").isEmpty)
        #expect(links("`a/b` /etcetera/x").isEmpty)
    }

    /// Lawrence 2026-10-23: the Cloud Chief's `**https://github.com/login/device**` showed as
    /// bold text you could not click. A bare web URL links, in bold, in a sentence, in a list.
    @Test func aBareWebURLInBoldIsALink() {
        let found = links("Open **https://github.com/login/device** and enter the code.")
        #expect(found.map(\.0) == ["https://github.com/login/device"])
        #expect(found.map(\.1) == ["https://github.com/login/device"])
    }

    @Test func aBareWebURLInASentenceIsALinkWithoutItsPunctuation() {
        #expect(links("PR is https://github.com/manaflow-ai/cmux/pull/1.").map(\.1) == ["https://github.com/manaflow-ai/cmux/pull/1"])
        #expect(links("- see https://x.com/a/b, then http://example.com/q?a=1&b=2!").map(\.1) == ["https://x.com/a/b", "http://example.com/q?a=1&b=2"])
        #expect(links("(https://example.com/x)").map(\.1) == ["https://example.com/x"])
        // The path inside a URL is part of the URL, never a path link of its own.
        #expect(links("https://example.com/Users/me/a.md").map(\.1) == ["https://example.com/Users/me/a.md"])
    }

    @Test func aMarkdownWebLinkKeepsItsName() {
        let found = links("Sign in at **[github.com/login/device](https://github.com/login/device)**.")
        #expect(found.map(\.0) == ["github.com/login/device"])
        #expect(found.map(\.1) == ["https://github.com/login/device"])
    }

    @Test func refusedSchemesNeverLink() {
        #expect(links("[x](javascript:alert(1)) [y](data:text/html,hi) [z](file://evil.com/etc/passwd)").isEmpty)
        #expect(URL(string: "file://evil.com/x")?.isHomePathLink == false)
        #expect(URL(string: "file:///x?q=1")?.isHomePathLink == false)
    }
}
