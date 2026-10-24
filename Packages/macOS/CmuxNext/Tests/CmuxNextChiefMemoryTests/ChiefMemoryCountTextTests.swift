@testable import CmuxNextChiefMemory
import Foundation
import Testing

/// The Memory Inspector's counts follow a label, so no noun has to agree with them ("1 lines" is gone).
@MainActor
struct ChiefMemoryCountTextTests {
    @Test func countsFollowALabel() {
        let latin = Locale(identifier: "en_US@numbers=latn")
        #expect(ChiefMemoryStrings.counts(messages: 3, summaryLines: 1, preferredLocalizations: ["en"], locale: latin)
            == "Messages: 3. Summary lines: 1.")
        #expect(ChiefMemoryStrings.rebuilding(1, preferredLocalizations: ["en"], locale: latin) == "Lines to rebuild: 1")
    }
}
