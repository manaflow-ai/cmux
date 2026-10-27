import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A question's HTML option preview draws in a frame the pane writes itself (`about:srcdoc`,
/// question/HtmlPreview.tsx). The pane's navigation policy lets exactly that subframe document
/// load, and never as the pane's own page or with anything after it.
@MainActor
struct AgentPaneHtmlPreviewFrameTests {
    private let srcdoc = URL(string: "about:srcdoc")!

    @Test func aPreviewFrameLoadsOnlyAsASubframe() {
        #expect(AgentPaneNavigation.decision(for: srcdoc, userClicked: false, mainFrame: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: srcdoc, userClicked: false, mainFrame: true) == .cancel)
    }

    @Test func otherAboutAndDataDocumentsStayCancelled() {
        for text in ["about:srcdoc?x", "about:srcdocx", "about:config", "data:text/html,<p>x</p>"] {
            let url = URL(string: text)!
            #expect(AgentPaneNavigation.decision(for: url, userClicked: false, mainFrame: false) == .cancel,
                    "\(text) loaded in a subframe")
        }
    }
}
