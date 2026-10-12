import Foundation
import Testing
@testable import CmuxMobileRPC

/// The decoder `userInfo` keys are built from string literals through the failable
/// `CodingUserInfoKey.init?(rawValue:)` and stored as optionals, so a decode never traps.
/// These pin that every literal produces a key, so the parser reuse and the bounded feed
/// options actually reach `init(from:)`.
@Suite("Mobile RPC decoder userInfo keys")
struct MobileRPCCodingUserInfoKeyTests {
    @Test("Every userInfo key literal produces a key")
    func everyKeyLiteralParses() {
        #expect(MobileRPCISO8601DateParser.userInfoKey != nil)
        #expect(CodingUserInfoKey.mobileNotificationFeedListBoundedDecodeOptions != nil)
    }

    @Test("A parser's decoder carries that parser to init(from:)")
    func decoderCarriesTheParser() throws {
        let key = try #require(MobileRPCISO8601DateParser.userInfoKey)
        let decoder = MobileRPCISO8601DateParser().decoder()
        #expect(decoder.userInfo[key] is MobileRPCISO8601DateParser)
    }
}
