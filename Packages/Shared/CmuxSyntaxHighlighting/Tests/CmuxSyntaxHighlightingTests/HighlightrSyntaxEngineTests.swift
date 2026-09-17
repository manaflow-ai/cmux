@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite("Highlightr syntax engine")
struct HighlightrSyntaxEngineTests {
    @Test("Policy rejection returns nil without coloring")
    func policyRejectionReturnsNil() async {
        let engine = HighlightrSyntaxEngine()
        let highlighted = await engine.highlight(
            text: #"{"a":1}"#,
            language: nil,
            theme: .light
        )
        #expect(highlighted == nil)
    }

}
