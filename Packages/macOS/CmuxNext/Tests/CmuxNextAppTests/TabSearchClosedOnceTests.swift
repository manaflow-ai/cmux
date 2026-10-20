@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Search Tabs' closed section lists a page closed again once, at its newest close, as Recently
/// Closed does, and Forget on that row deletes every close of the page, so no older one takes its
/// place. A terminal carries nothing that tells one close from another: each close stays its
/// own row, and Forget deletes only it. A page on another machine is another page.
@MainActor
struct TabSearchClosedOnceTests {
    private typealias Closed = (item: CmuxNextDaemon.ClosedItem, machine: String)

    private static func browser(_ url: String) -> String {
        """
        {"kind":"browser","name":null,"cwd":null,"url":"\(url)","browser_profile_id":null,"pinned":false}
        """
    }

    private static let terminal = """
        {"kind":"terminal","name":null,"cwd":"/Users/you","url":null,"browser_profile_id":null,"pinned":false}
        """

    /// One closed tab item as `closed.list` lists it, closed at `at`.
    private static func closed(_ id: String, at: Int, _ tab: String, machine: String = "local") throws -> Closed {
        let json = """
        {"id":"\(id)","kind":"tab","name":null,"workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":\(at),
         "screens":[{"name":null,"tabs":[\(tab)]}],"window":null,"member_count":1,"members":[]}
        """
        return (try JSONDecoder().decode(CmuxNextDaemon.ClosedItem.self, from: Data(json.utf8)), machine)
    }

    @Test func aPageClosedAgainIsListedOnceAndForgottenWhole() throws {
        let newestFirst = try [
            Self.closed("cmux", at: 6, Self.browser("https://cmux.com/")),
            Self.closed("example-3", at: 5, Self.browser("https://example.com/")),
            Self.closed("shell-2", at: 4, Self.terminal),
            Self.closed("example-other-mac", at: 3, Self.browser("https://example.com/"), machine: "studio"),
            Self.closed("example-2", at: 2, Self.browser("https://example.com/")),
            Self.closed("shell-1", at: 1, Self.terminal),
            Self.closed("example-1", at: 0, Self.browser("https://example.com/")),
        ]
        let listed = TabSearchFactsBuilder.listed(newestFirst) { $0 }
        #expect(listed.map(\.item.id) == ["cmux", "example-3", "shell-2", "example-other-mac", "shell-1"])

        let forgotten = { (id: String) in
            let target = try #require(newestFirst.first { $0.item.id == id })
            return TabSearchFactsBuilder.forgotten(target, among: newestFirst) { $0 }.map(\.item.id).sorted()
        }
        #expect(try forgotten("example-3") == ["example-1", "example-2", "example-3"])
        #expect(try forgotten("shell-2") == ["shell-2"])
    }
}
