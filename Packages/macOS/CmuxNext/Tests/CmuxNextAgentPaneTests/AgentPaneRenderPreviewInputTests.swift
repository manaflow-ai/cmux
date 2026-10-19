import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneRenderPreviewInputTests {
    @Test func acceptsReplyAndPhoneWidths() throws {
        let widths: [Int?] = [nil, 320, 390, 1440]
        for width in widths {
            let input = try AgentPaneRenderPreviewInput(html: "<p>Hello</p>", width: width)
            #expect(input.width == width)
            #expect(input.html == "<p>Hello</p>")
        }
    }

    @Test func refusesEmptyOversizedAndInvalidWidths() {
        for html in ["", " \n", String(repeating: "x", count: (1 << 20) + 1), String(repeating: "é", count: (1 << 19) + 1)] {
            #expect(throws: URLError.self) { try AgentPaneRenderPreviewInput(html: html, width: nil) }
        }
        for width in [-1, 0, 319, 1441] {
            #expect(throws: URLError.self) { try AgentPaneRenderPreviewInput(html: "x", width: width) }
        }
    }

    @Test func acceptsExactlyOneMiB() throws {
        #expect(try AgentPaneRenderPreviewInput(html: String(repeating: "x", count: 1 << 20), width: nil).html.utf8.count == 1 << 20)
    }
}

@MainActor
struct AgentPaneRenderPreviewNavigationTests {
    @Test func onlyBootstrapDocumentsAreAllowed() {
        #expect(AgentPaneRenderPreview.allowsInitialDocument(URL(string: "about:blank"), mainFrame: true))
        #expect(AgentPaneRenderPreview.allowsInitialDocument(URL(string: "cmux-agent://render/frame"), mainFrame: false))
        for url in ["https://example.com", "file:///tmp/a", "cmux-agent://index.html", "about:blank"] {
            #expect(!AgentPaneRenderPreview.allowsInitialDocument(URL(string: url), mainFrame: false))
        }
        #expect(!AgentPaneRenderPreview.allowsInitialDocument(nil, mainFrame: true))
        #expect(AgentPaneRenderPreview().responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
    }
}
