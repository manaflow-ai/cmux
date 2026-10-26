@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A What's New highlight's PR chip shows the agent page's link hover card, which calls each
/// method `m` as `cmux.changelog.<m>`. The changelog page answers the card's three methods,
/// `pr.inspect`, `browser.list` and `browser.openIn`, with the agent page's params and replies;
/// `browser.openIn` opens only https and only on the person's own click or key in the page.
@MainActor @Suite struct ChangelogPRChipTests {
    static let pullRequestURL = URL(string: "https://github.com/manaflow-ai/cmux/pull/24000")!
    static let answer = AgentPanePullRequestAnswer(
        pullRequest: AgentPanePullRequest(url: pullRequestURL.absoluteString, number: 24000, title: "Retry", state: "open",
                                          checks: .init(state: "passing", passed: 3, total: 3), labels: ["risk:normal"],
                                          author: "octocat"),
        fetchedAt: 1_792_000_000, reading: true)
    static let gesture = PageCallContext(page: "cmux.changelog", userGesture: true, gestureEvent: 100)
    static let noGesture = PageCallContext(page: "cmux.changelog")

    /// The installed browsers, as the card's Open in menu lists them; records each open.
    @MainActor final class Browsers: AgentPaneBrowserApps {
        var opened: [(URL, URL)] = []
        func applications() -> [URL] { [URL(fileURLWithPath: "/Applications/Firefox.app")] }
        func displayName(of app: URL) -> String { "Firefox" }
        func iconPNG(of app: URL) -> Data? { nil }
        func open(_ url: URL, withApplicationAt app: URL) { opened.append((url, app)) }
    }

    /// A changelog page whose pull request cache answers `answer` and whose cmux opener records each URL.
    @MainActor final class Rig {
        var asked: [URL] = []
        var opened: [URL] = []
        var opens = true
        let browsers = Browsers()
        lazy var links: AgentPaneReplyLinks = {
            let links = AgentPaneReplyLinks()
            links.pullRequest = { [unowned self] url in asked.append(url); return ChangelogPRChipTests.answer }
            links.browsers = browsers
            return links
        }()
        lazy var page = ChangelogPageProvider(source: nil, currentBuild: "4242", links: links,
                                              openLink: { [unowned self] url, _ in opened.append(url); return opens })

        func call(_ method: String, _ params: JSONValue, _ context: PageCallContext = ChangelogPRChipTests.gesture) async throws -> JSONValue {
            try await page.call("cmux.changelog." + method, params: params, context: context)
        }

        func openIn(_ url: String, browserId: String = "cmux", _ context: PageCallContext = ChangelogPRChipTests.gesture) async throws -> JSONValue {
            try await call("browser.openIn", ["url": .string(url), "browserId": .string(browserId)], context)
        }
    }

    // MARK: pr.inspect

    @Test func prInspectAnswersWithTheAgentPagesReply() async throws {
        let rig = Rig()
        let changelog = try await rig.call("pr.inspect", ["url": .string(Self.pullRequestURL.absoluteString)], Self.noGesture)
        // The agent page's own reply for the same cache answer.
        let links = AgentPaneReplyLinks()
        links.pullRequest = { _ in Self.answer }
        let agent = try AgentPageProvider.value(of: links.respondToPullRequest(Self.pullRequestURL))
        #expect(changelog == agent)
        #expect(changelog["pullRequest"]?["number"]?.intValue == 24000)
        #expect(changelog["reading"]?.boolValue == true)
        #expect(changelog["fetchedAt"]?.doubleValue == 1_792_000_000)
        #expect(rig.asked == [Self.pullRequestURL])
    }

    @Test func prInspectWithNoAnswerYetIsANullPullRequest() async throws {
        let links = AgentPaneReplyLinks()
        let page = ChangelogPageProvider(source: nil, currentBuild: "", links: links)
        let reply = try await page.call("cmux.changelog.pr.inspect", params: ["url": .string(Self.pullRequestURL.absoluteString)],
                                        context: Self.noGesture)
        #expect(reply == ["pullRequest": .null, "reading": .bool(false)])
    }

    @Test(arguments: ["https://example.com/o/r/pull/1", "https://github.com/o/r/issues/1", "http://github.com/o/r/pull/1",
                      "https://github.com/o/r/pull/1?x=1", "javascript:alert(1)", ""])
    func prInspectRefusesAnythingButAPullRequest(_ url: String) async throws {
        let rig = Rig()
        await #expect(throws: PageError.self) { _ = try await rig.call("pr.inspect", ["url": .string(url)]) }
        #expect(rig.asked.isEmpty)
    }

    // MARK: browser.list and browser.openIn

    @Test func browserListNamesTheInstalledBrowsersByOpaqueID() async throws {
        let rig = Rig()
        let reply = try await rig.call("browser.list", [:], Self.noGesture)
        let browsers = try #require(reply["browsers"]?.arrayValue)
        #expect(browsers.count == 1)
        #expect(browsers.first?["name"]?.stringValue == "Firefox")
        let id = try #require(browsers.first?["id"]?.stringValue)
        #expect(!id.contains("Firefox"))
        // That id opens the link in that browser, on a gesture.
        #expect(try await rig.openIn(Self.pullRequestURL.absoluteString, browserId: id) == .null)
        #expect(rig.browsers.opened.map(\.0) == [Self.pullRequestURL])
        #expect(rig.browsers.opened.map(\.1.lastPathComponent) == ["Firefox.app"])
    }

    @Test func anUnlistedBrowserIsRefused() async throws {
        let rig = Rig()
        let error = await #expect(throws: PageError.self) {
            _ = try await rig.openIn(Self.pullRequestURL.absoluteString, browserId: "not-listed")
        }
        #expect(error?.code == AgentPaneReplyError.browserUnknown.rawValue)
        #expect(rig.browsers.opened.isEmpty)
    }

    @Test func anHttpsLinkWithAGestureOpensInACmuxTab() async throws {
        let rig = Rig()
        #expect(try await rig.openIn(Self.pullRequestURL.absoluteString) == .null)
        #expect(rig.opened == [Self.pullRequestURL])
    }

    @Test func aLinkWithoutAGestureIsRefused() async throws {
        let rig = Rig()
        let error = await #expect(throws: PageError.self) {
            _ = try await rig.openIn(Self.pullRequestURL.absoluteString, browserId: "cmux", Self.noGesture)
        }
        #expect(error?.code == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(rig.opened.isEmpty)
    }

    /// Page script inside the gesture's second cannot open a second link on the click the first used.
    @Test func oneGestureOpensOneLink() async throws {
        let rig = Rig()
        _ = try await rig.openIn(Self.pullRequestURL.absoluteString)
        await #expect(throws: PageError.self) { _ = try await rig.openIn(Self.pullRequestURL.absoluteString) }
        _ = try await rig.openIn(Self.pullRequestURL.absoluteString, browserId: "cmux",
                                 PageCallContext(page: "cmux.changelog", userGesture: true, gestureEvent: 101))
        #expect(rig.opened.count == 2)
    }

    @Test(arguments: ["http://github.com/o/r/pull/1", "HTTP://github.com/o/r/pull/1", "file:///etc/passwd", "javascript:alert(1)",
                      "cmux://open", "https://user:pass@github.com/", "https://", "not a url", ""])
    func aLinkThatIsNotHttpsIsRefused(_ url: String) async throws {
        let rig = Rig()
        let error = await #expect(throws: PageError.self) { _ = try await rig.openIn(url) }
        #expect(error?.code == "cmux.protocol.invalid_params")
        #expect(rig.opened.isEmpty)
    }

    @Test func aMalformedCallIsRefused() async throws {
        let rig = Rig()
        let https = JSONValue.string(Self.pullRequestURL.absoluteString)
        for params: JSONValue in [[:], ["url": https], ["url": .number(1), "browserId": "cmux"], ["url": https, "browserId": "cmux", "x": "y"]] {
            await #expect(throws: PageError.self) { _ = try await rig.call("browser.openIn", params) }
        }
        #expect(rig.opened.isEmpty)
    }

    @Test func anOpenThatFailsIsAnError() async throws {
        let rig = Rig()
        rig.opens = false
        let error = await #expect(throws: PageError.self) { _ = try await rig.openIn(Self.pullRequestURL.absoluteString) }
        #expect(error?.code == AgentPaneReplyError.openFailed.rawValue)
    }

    /// Only the card's three methods: the agent page's other link requests are not the changelog page's.
    @Test(arguments: ["link.open", "link.openPath", "link.inspect", "image.load", "image.openInPane", "browser.open"])
    func otherMethodsAreUnknown(_ method: String) async throws {
        let rig = Rig()
        let error = await #expect(throws: PageError.self) {
            _ = try await rig.call(method, ["url": .string(Self.pullRequestURL.absoluteString)])
        }
        #expect(error?.code == "cmux.protocol.unknown_op")
    }
}
