import Foundation
import Testing
@testable import CmuxNextPages

/// A page's main frame never leaves its own document: a link relative to the page
/// (`cmux-page://<id>/README.md`, `..`, `//host`) is on the page's origin, so without this rule it
/// would replace the page and drop its state. Only the page's entry and its fragments load there.
@MainActor
@Suite struct PageMainFrameTests {
    private let page = PageDescriptor(id: "cmux.agent", resource: "agent-pane", namespaces: ["cmux.agent."])

    private func policy(_ string: String, clicked: Bool = true, mainFrame: Bool = true,
                        hook: ((PageNavigation) -> PageNavigation.Policy)? = nil) -> PageNavigation.Policy {
        PageNavigation.policy(for: URL(string: string), page: page, userClicked: clicked, mainFrame: mainFrame, hook: hook)
    }

    @Test func thePagesEntryAndItsFragmentsLoad() {
        #expect(policy("cmux-page://cmux.agent/") == .allow)
        #expect(policy("cmux-page://cmux.agent/#/turn-4", clicked: false) == .allow)
        #expect(policy("cmux-page://cmux.agent/index.html") == .allow)
        #expect(policy("cmux-page://cmux.agent") == .allow)
    }

    @Test func anotherDocumentOnThePagesOriginNeverReplacesIt() {
        for path in ["README.md", "docs/a.html", "..", "%2E%2E/x", "/x", "?x=1"] {
            #expect(policy("cmux-page://cmux.agent/\(path)") == .cancel, "\(path)")
            #expect(policy("cmux-page://cmux.agent/\(path)", clicked: false) == .cancel, "\(path)")
        }
    }

    /// The page's own origin never reaches the hook, so a hook cannot allow it either.
    @Test func theHookIsNotAskedAboutThePagesOrigin() {
        var asked = 0
        let decided = policy("cmux-page://cmux.agent/README.md") { _ in
            asked += 1
            return .allow
        }
        #expect(decided == .cancel)
        #expect(asked == 0)
    }

    /// Every page the host ships routes by fragment only: its first load (``PageDescriptor/url(route:)``)
    /// and a route change keep the main frame; a path or query on its origin does not.
    @Test(arguments: [PageDescriptor.cloud, .settings, .apps, .coderouter, .changelog, .history, .diff, .markdown, .editor])
    func everyPageRoutesByFragmentOnly(_ descriptor: PageDescriptor) {
        func policy(_ url: URL) -> PageNavigation.Policy {
            PageNavigation.policy(for: url, page: descriptor, userClicked: false, mainFrame: true, hook: nil)
        }
        #expect(policy(descriptor.url()) == .allow, "\(descriptor.id)")
        #expect(policy(descriptor.url(route: "#/x/y?focus=1")) == .allow, "\(descriptor.id)")
        #expect(policy(descriptor.url().appendingPathComponent("other")) == .cancel, "\(descriptor.id)")
        let query = URL(string: descriptor.url().absoluteString + "?file=a")
        #expect(PageNavigation.policy(for: query, page: descriptor, userClicked: false, mainFrame: true, hook: nil) == .cancel)
    }
}
