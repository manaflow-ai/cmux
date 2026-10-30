@testable import CmuxNextAgentPane
import CmuxNextPages
import Foundation
import Testing

/// The agent page's artifacts on the shared page host (`PageNavigation.policy` with the agent page's
/// descriptor): the one-shot artifact endpoint (`cmux-page://cmux.agent/__artifact`) and a passive
/// srcdoc artifact never navigate anywhere, not even to a document the pane itself may load (its
/// render frame, a loopback preview), whatever the page's navigation hook would answer.
@MainActor
struct AgentPaneArtifactNavigationTests {
    private let page = PageDescriptor.agent

    /// The agent page's own hook, as `AgentPaneView.attachPage` sets it.
    private static func paneHook(_ navigation: PageNavigation) -> PageNavigation.Policy {
        switch AgentPaneNavigation.decision(for: navigation.url, userClicked: navigation.userClicked, mainFrame: navigation.mainFrame) {
        case .allow: .allow
        case .openOutside: .openExternal
        case .cancel: .cancel
        }
    }

    /// The pane's hook, and one that allows everything: the refusal is the host's, not the hook's.
    private var hooks: [(PageNavigation) -> PageNavigation.Policy] { [Self.paneHook, { _ in .allow }] }

    @Test func artifactsCannotNavigateEvenToAnotherAllowedFrame() throws {
        let pane = try #require(URL(string: "cmux-page://cmux.agent/"))
        let frame = try #require(URL(string: AgentPaneRenderFrame.artifactSource))
        for hook in hooks {
            #expect(PageNavigation.policy(for: frame, page: page, userClicked: false, mainFrame: false,
                                          sourceFrameURL: pane, hook: hook) == .allow, "the pane makes its artifact frame")
        }
        for text in ["http://127.0.0.1:8080/leak", "https://example.com", "file:///tmp/private", AgentPaneRenderFrame.source,
                     "about:srcdoc"] {
            let url = try #require(URL(string: text))
            for main in [true, false] {
                // The artifact navigating itself, or the page it sits in (`top.location`).
                let target = main ? pane : frame
                for hook in hooks {
                    #expect(PageNavigation.policy(for: url, page: page, userClicked: true, mainFrame: main,
                                                  targetFrameURL: target, sourceFrameURL: frame, hook: hook) == .cancel,
                            "\(text) from the artifact")
                    #expect(PageNavigation.policy(for: url, page: page, userClicked: false, mainFrame: main,
                                                  targetFrameURL: frame, sourceFrameURL: pane, hook: hook) == .cancel,
                            "\(text) in the artifact's frame")
                }
            }
        }
    }

    @Test func srcdocArtifactCannotNavigateOutOfItsSandbox() throws {
        let pane = try #require(URL(string: "cmux-page://cmux.agent/"))
        let srcdoc = try #require(URL(string: "about:srcdoc"))
        for text in ["http://127.0.0.1:8080/leak", "https://example.com", "file:///tmp/private", "cmux-page://cmux.agent/"] {
            let url = try #require(URL(string: text))
            for hook in hooks {
                #expect(PageNavigation.policy(for: url, page: page, userClicked: true, mainFrame: false,
                                              targetFrameURL: srcdoc, sourceFrameURL: srcdoc, hook: hook) == .cancel, "\(text)")
            }
        }
        // The parent is allowed to create its srcdoc child; only a navigation that originated there is refused.
        for hook in hooks {
            #expect(PageNavigation.policy(for: srcdoc, page: page, userClicked: false, mainFrame: false,
                                          sourceFrameURL: pane, hook: hook) == .allow)
        }
    }
}
