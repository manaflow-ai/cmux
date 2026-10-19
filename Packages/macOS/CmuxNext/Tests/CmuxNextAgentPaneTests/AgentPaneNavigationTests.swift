import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneNavigationTests {
    private let bundled = AgentPaneSource.bundled(URL(fileURLWithPath: "/tmp/agent-pane/index.html"))
    private let dev = AgentPaneSource.devServer(URL(string: "http://127.0.0.1:4176/")!)
    private let render = URL(string: "cmux-agent://render/frame")!
    private let devRender = URL(string: "http://127.0.0.1:4176/__cmux-render-frame")!

    @Test func renderDocumentLoadsOnlyIntoAnEmptyFrame() {
        for (source, frame) in [(bundled, render), (dev, devRender)] {
            for target in [nil, URL(string: "about:blank")] {
                #expect(AgentPaneNavigation.decision(for: frame, source: source, userClicked: false,
                                                     mainFrame: false, targetFrameURL: target) == .allow)
            }
            #expect(AgentPaneNavigation.decision(for: frame, source: source, userClicked: false,
                                                 mainFrame: false, targetFrameURL: frame) == .cancel)
            #expect(AgentPaneNavigation.decision(for: frame, source: source, userClicked: false,
                                                 mainFrame: false,
                                                 targetFrameURL: URL(string: "http://localhost:3000/")) == .cancel)
        }
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4176/other"), source: dev,
                                             userClicked: false, mainFrame: false) == .cancel)
        // The render path on another origin is still an ordinary loopback preview.
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4177/__cmux-render-frame"), source: dev,
                                             userClicked: false, mainFrame: false) == .allow)
    }

    @Test func renderFrameCannotNavigateAfterItsFirstLoad() {
        for (source, frame) in [(bundled, render), (dev, devRender)] {
            for url in ["http://127.0.0.1:3000/mutate", "http://localhost:8080/", frame.absoluteString,
                        frame.absoluteString + "#again", "about:blank", "https://example.com/"] {
                for clicked in [false, true] {
                    // The parent can initiate a navigation too: the target, not just the source,
                    // identifies the already loaded render document.
                    #expect(AgentPaneNavigation.decision(for: URL(string: url), source: source, userClicked: clicked,
                                                         mainFrame: false, targetFrameURL: frame,
                                                         sourceFrameURL: source.pageURL) == .cancel)
                    #expect(AgentPaneNavigation.decision(for: URL(string: url), source: source, userClicked: clicked,
                                                         mainFrame: false, targetFrameURL: frame,
                                                         sourceFrameURL: frame) == .cancel)
                }
            }
        }
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:3000/mutate"), source: bundled,
                                             userClicked: true, sourceFrameURL: render) == .cancel)
    }

    @Test func previewSubframesKeepTheirLoopbackNavigation() {
        let preview = URL(string: "http://localhost:3000/")!
        for source in [bundled, dev] {
            for clicked in [false, true] {
                #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:8080/next"), source: source,
                                                     userClicked: clicked, mainFrame: false,
                                                     targetFrameURL: preview, sourceFrameURL: preview) == .allow)
                #expect(AgentPaneNavigation.decision(for: source.pageURL, source: source,
                                                     userClicked: clicked, mainFrame: false,
                                                     targetFrameURL: preview, sourceFrameURL: preview) == .cancel)
                #expect(AgentPaneNavigation.decision(for: URL(string: "https://example.com/"), source: source,
                                                     userClicked: clicked, mainFrame: false,
                                                     targetFrameURL: preview, sourceFrameURL: preview) == .cancel)
            }
        }
    }

    @Test func mainFrameRulesStayTheSame() {
        for (source, frame) in [(bundled, render), (dev, devRender)] {
            #expect(AgentPaneNavigation.decision(for: source.pageURL, source: source, userClicked: false) == .allow)
            #expect(AgentPaneNavigation.decision(for: frame, source: source, userClicked: false) == .cancel)
            let link = URL(string: "http://127.0.0.1:3000/")!
            #expect(AgentPaneNavigation.decision(for: link, source: source, userClicked: false) == .cancel)
            #expect(AgentPaneNavigation.decision(for: link, source: source, userClicked: true) == .openOutside(link))
        }
        #expect(AgentPaneNavigation.decision(for: nil, source: bundled, userClicked: true) == .cancel)
    }

    @Test func sharedPageHostPassesFrameDocumentsToThePanePolicy() {
        for frame in [render, URL(string: "about:srcdoc")!, URL(string: "about:srcdoc?state=1#fragment")!] {
            for url in [URL(string: "http://127.0.0.1:3000/mutate")!, PageDescriptor.agent.url(), render] {
                let policy = PageNavigation.policy(for: url, page: .agent, userClicked: false, mainFrame: false,
                                                   targetFrameURL: frame, sourceFrameURL: frame) { navigation in
                    switch AgentPaneNavigation.decision(for: navigation, source: bundled) {
                    case .allow: return .allow
                    case .openOutside: return .openExternal
                    case .cancel: return .cancel
                    }
                }
                #expect(policy == .cancel)
            }
        }
    }
}
