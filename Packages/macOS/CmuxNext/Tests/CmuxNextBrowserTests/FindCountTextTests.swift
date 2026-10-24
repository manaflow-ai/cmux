@testable import CmuxNextBrowser
import Foundation
import Testing

/// The find bar's count agrees with the number of matches ("1 match", not "1 matches").
@MainActor
struct FindCountTextTests {
    @Test func englishAgreesWithTheCount() {
        let latin = Locale(identifier: "en_US@numbers=latn")
        #expect(Strings.findCount(1, preferredLocalizations: ["en"], locale: latin) == "1 match")
        #expect(Strings.findCount(3, preferredLocalizations: ["en"], locale: latin) == "3 matches")
    }
}
