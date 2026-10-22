import Foundation
import Testing
@testable import MessagesLabHome

/// Lawrence 2026-10-22: "why did u forget to link a459" and "none of these worked". A Chief's
/// reply named subagents bare (`**a459**`, `a466`, `(a468)`) and workspaces by key
/// (`cmux://workspace/f8d01127-…`): Home links every subagent the app knows, whichever Chief wrote
/// the id and however Markdown wraps it, and a workspace key link is an app link. An id the app
/// does not know stays plain text.
@Suite(.serialized) struct HomeSubagentLinksTests {
    /// The Mac Chief's subagents, as the app reads them from its home's acpmux lanes.
    static let known: [String: String] = [
        "a459": "cmux://chief/2e448bc2/session/01a161e0-f2df-7e21-83d4-fc229778848e",
        "a466": "cmux://chief/2e448bc2/session/01a161f0-0000-7000-8000-000000000466",
        "a467": "cmux://chief/2e448bc2/session/01a161f0-0000-7000-8000-000000000467",
        "a468": "cmux://chief/2e448bc2/session/01a161f0-0000-7000-8000-000000000468",
    ]

    init() {
        HomeMarkdownPolicy.install()
        HomeSubagentLinks.shared.set(Self.known)
    }

    /// The (shown text, link) pairs of `markdown` rendered.
    func links(_ markdown: String) -> [(String, String)] {
        let (text, runs) = HomeMarkdown.render(markdown)
        let ns = text as NSString
        return runs.compactMap { run in run.link.map { (ns.substring(with: NSRange(location: run.start, length: run.length)), $0) } }
    }

    @Test func aBareIdInBoldLinksToItsChat() {
        let found = links("**a459** is still running.")
        #expect(found.map(\.0) == ["a459"])
        #expect(found.map(\.1) == [Self.known["a459"]])
    }

    @Test func aBareIdInAListItemLinks() {
        let found = links("- a466: Subagents in Freestyle VMs (cancelled)\n- **a467**: Agent ids always linked")
        #expect(found.map(\.0) == ["a466", "a467"])
        #expect(found.map(\.1) == [Self.known["a466"], Self.known["a467"]])
    }

    @Test func aBareIdInParenthesesLinks() {
        let found = links("Home list loading (a468) and the hub (a459, a466).")
        #expect(found.map(\.0) == ["a468", "a459", "a466"])
    }

    /// The Cloud Chief's reply: it did not spawn a459 and wrote no link, but the app knows the
    /// Mac Chief's a459, so Home links it in that reply as well.
    @Test func aCloudChiefReplyLinksTheMacChiefsSubagents() {
        let reply = "Cloud Chief here. **a459** (Cloud Chief reaches all Macs) and a463 are on it; ask a453 too."
        let found = links(reply)
        #expect(found.map(\.0) == ["a459"])
        #expect(found.allSatisfy { URL(string: $0.1)?.isChiefSubagentLink == true })
    }

    @Test func anUnknownIdOrOneInsideAWordStaysPlain() {
        #expect(links("a999 and **a998** wait.").isEmpty)
        #expect(links("ma459, a459b, /a459, a459.txt, #a459, @a459, foo_a459, a459_x").isEmpty)
        #expect(links("`a459` in code").isEmpty)
    }

    /// The links in the report that opened nothing: workspace keys, not `ws_` ids.
    @Test func aWorkspaceKeyLinkIsAnAppLink() {
        for key in ["f8d01127-5c4a-45d5-8568-50a56041a6b6", "6885841b-99b4-4755-a336-2151a8f80ff5",
                    "1b9a583f-df9f-4ee8-9f88-1a0ae3deca2f"] {
            let link = "cmux://workspace/\(key)"
            #expect(URL(string: link)?.isCmuxAppLink == true, "\(link)")
            #expect(links("Workspace: \(link)").map(\.1) == [link], "\(link)")
            #expect(links("[a468 workspace](\(link))").map(\.1) == [link], "\(link)")
        }
        #expect(URL(string: "cmux://workspace/not-a-key")?.isCmuxAppLink == false)
    }

    @Test func aStreamingLineRendersAgainOnceTheSubagentIsKnown() {
        let cache = HomeMarkdownLineCache(chips: false)
        let registry = HomeSubagentLinks.shared
        registry.set(Self.known.filter { $0.key != "a466" })
        #expect(cache.rendered("- a466: queued").runs.allSatisfy { $0.link == nil })
        registry.set(Self.known)
        #expect(cache.rendered("- a466: queued").runs.compactMap(\.link) == [Self.known["a466"]])
    }
}
