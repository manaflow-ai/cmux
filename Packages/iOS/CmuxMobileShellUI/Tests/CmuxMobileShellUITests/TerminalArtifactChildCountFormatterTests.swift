import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite("Terminal artifact child-count formatting")
struct TerminalArtifactChildCountFormatterTests {
    @Test("resolves English inflection markup into singular and plural text")
    func englishInflection() {
        let formatter = TerminalArtifactChildCountFormatter(locale: Locale(identifier: "en"))

        #expect(formatter.string(count: 1, isCapped: false) == "1 item")
        #expect(formatter.string(count: 11, isCapped: false) == "11 items")
        #expect(!formatter.string(count: 11, isCapped: false).contains("inflect"))
        #expect(formatter.string(count: 500, isCapped: true) == "500+ items")
    }

    @Test("uses the Japanese localized count without English inflection markup")
    func japaneseCount() {
        let formatter = TerminalArtifactChildCountFormatter(locale: Locale(identifier: "ja"))

        #expect(formatter.string(count: 1, isCapped: false) == "1項目")
        #expect(formatter.string(count: 11, isCapped: false) == "11項目")
        #expect(formatter.string(count: 500, isCapped: true) == "500項目以上")
    }
}
