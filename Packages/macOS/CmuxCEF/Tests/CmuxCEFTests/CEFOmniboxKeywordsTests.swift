import Foundation
import Testing
@testable import CmuxCEF

/// The fork's chrome.omnibox JSON (fork API 12, cef_cmux.h).
@Suite
struct CEFOmniboxKeywordsTests {
    @Test
    func decodesKeywordsOfEnabledExtensions() {
        let json = #"""
        [{"extension_id":"abc","keyword":"nt","name":"Notes","icon_png":"","default_description":"Search %s"},
         {"extension_id":"def","keyword":"gh","name":""},
         {"extension_id":"","keyword":"zz","name":"Broken"}]
        """#
        #expect(CEFOmniboxKeywords.keywords(json: json) == [
            CEFOmniboxKeyword(extensionID: "abc", keyword: "nt", name: "Notes", defaultDescription: "Search %s"),
            CEFOmniboxKeyword(extensionID: "def", keyword: "gh", name: "gh", defaultDescription: nil),
        ])
        #expect(CEFOmniboxKeywords.keywords(json: "null").isEmpty)
    }

    @Test
    func decodesSuggestionRows() {
        let json = #"[{"content":"milk tea","description":"Milk tea","deletable":false,"styles":[]},{"content":""},{"content":"x"}]"#
        #expect(CEFOmniboxKeywords.suggestions(json: json) == [
            CEFOmniboxSuggestion(content: "milk tea", description: "Milk tea"),
            CEFOmniboxSuggestion(content: "x", description: "x"),
        ])
    }

    @Test
    func suggestionEventDecodesItsRequest() {
        let event = CEFShimEvent(kind: 30, browser: 0, request: 7, a: 0, b: 0, s1: "abc", s2: "[]")
        #expect(event == .omniboxSuggestions(requestID: 7, extensionID: "abc", json: "[]"))
    }
}
