@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A What's New highlight's PR chip shows the agent page's hover card, so the changelog page
/// answers the card's two calls itself: `cmux.changelog.pr.inspect` with exactly the agent page's
/// `pr.inspect` reply, and `cmux.changelog.link.open`, which opens only an https link and only on
/// the person's own click or key in the page.
@MainActor @Suite struct ChangelogPRChipTests {
    static let pullRequestURL = URL(string: "https://github.com/manaflow-ai/cmux/pull/24000")!
    static let answer = AgentPanePullRequestAnswer(
        pullRequest: AgentPanePullRequest(url: pullRequestURL.absoluteString, number: 24000, title: "Retry", state: "open",
                                          checks: .init(state: "passing", passed: 3, total: 3), labels: ["risk:normal"],
                                          author: "octocat"),
        fetchedAt: 1_792_000_000, reading: true)
    static let gesture = PageCallContext(page: "cmux.changelog", userGesture: true, gestureEvent: 100)

    /// A changelog page whose pull request cache answers `answer` and whose opener records each URL.
    @MainActor final class Rig {
        var asked: [URL] = []
        var opened: [URL] = []
        var opens = true
        lazy var page = ChangelogPageProvider(
            source: nil, currentBuild: "4242",
            pullRequests: { [unowned self] url in asked.append(url); return ChangelogPRChipTests.answer },
            openLink: { [unowned self] url, _ in opened.append(url); return opens })
    }

    @Test func prInspectAnswersWithTheAgentPagesReply() async throws {
        let rig = Rig()
        let changelog = try await rig.page.call("cmux.changelog.pr.inspect",
                                                params: ["url": .string(Self.pullRequestURL.absoluteString)],
                                                context: PageCallContext(page: "cmux.changelog"))
        // The agent page's own path for the same answer (AgentPaneReplyLinks, then the page reply).
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
        let page = ChangelogPageProvider(source: nil, currentBuild: "", pullRequests: { _ in .init() })
        let reply = try await page.call("cmux.changelog.pr.inspect", params: ["url": .string(Self.pullRequestURL.absoluteString)],
                                        context: PageCallContext(page: "cmux.changelog"))
        #expect(reply == ["pullRequest": .null, "reading": .bool(false)])
    }

    @Test(arguments: ["https://example.com/o/r/pull/1", "https://github.com/o/r/issues/1", "http://github.com/o/r/pull/1",
                      "https://github.com/o/r/pull/1?x=1", "javascript:alert(1)", ""])
    func prInspectRefusesAnythingButAPullRequest(_ url: String) async throws {
        let rig = Rig()
        await #expect(throws: PageError.self) {
            _ = try await rig.page.call("cmux.changelog.pr.inspect", params: ["url": .string(url)], context: Self.gesture)
        }
        #expect(rig.asked.isEmpty)
    }

    @Test func anHttpsLinkWithAGestureOpensInACmuxTab() async throws {
        let rig = Rig()
        let reply = try await rig.page.call("cmux.changelog.link.open", params: ["url": .string(Self.pullRequestURL.absoluteString)],
                                            context: Self.gesture)
        #expect(reply == .null)
        #expect(rig.opened == [Self.pullRequestURL])
    }

    @Test func aLinkWithoutAGestureIsRefused() async throws {
        let rig = Rig()
        let error = await #expect(throws: PageError.self) {
            _ = try await rig.page.call("cmux.changelog.link.open", params: ["url": .string(Self.pullRequestURL.absoluteString)],
                                        context: PageCallContext(page: "cmux.changelog"))
        }
        #expect(error?.code == PageNativeOp.userOnlyCode)
        #expect(rig.opened.isEmpty)
    }

    /// Page script inside the gesture's second cannot open a second link on the click the first used.
    @Test func oneGestureOpensOneLink() async throws {
        let rig = Rig()
        let url = JSONValue.string(Self.pullRequestURL.absoluteString)
        _ = try await rig.page.call("cmux.changelog.link.open", params: ["url": url], context: Self.gesture)
        await #expect(throws: PageError.self) {
            _ = try await rig.page.call("cmux.changelog.link.open", params: ["url": url], context: Self.gesture)
        }
        let next = PageCallContext(page: "cmux.changelog", userGesture: true, gestureEvent: 101)
        _ = try await rig.page.call("cmux.changelog.link.open", params: ["url": url], context: next)
        #expect(rig.opened.count == 2)
    }

    @Test(arguments: ["http://github.com/o/r/pull/1", "file:///etc/passwd", "javascript:alert(1)", "cmux://open",
                      "https://user:pass@github.com/", "https://", "not a url", ""])
    func aLinkThatIsNotHttpsIsRefused(_ url: String) async throws {
        let rig = Rig()
        let error = await #expect(throws: PageError.self) {
            _ = try await rig.page.call("cmux.changelog.link.open", params: ["url": .string(url)], context: Self.gesture)
        }
        #expect(error?.code == "cmux.protocol.invalid_params")
        #expect(rig.opened.isEmpty)
    }

    @Test func aMalformedCallIsRefused() async throws {
        let rig = Rig()
        let https = JSONValue.string(Self.pullRequestURL.absoluteString)
        for params: JSONValue in [[:], ["url": .number(1)], ["url": https, "browserId": "safari"], .null] {
            await #expect(throws: PageError.self) {
                _ = try await rig.page.call("cmux.changelog.link.open", params: params, context: Self.gesture)
            }
        }
        #expect(rig.opened.isEmpty)
    }

    @Test func anOpenThatFailsIsAnError() async throws {
        let rig = Rig()
        rig.opens = false
        await #expect(throws: PageError.self) {
            _ = try await rig.page.call("cmux.changelog.link.open", params: ["url": .string(Self.pullRequestURL.absoluteString)],
                                        context: Self.gesture)
        }
    }
}
