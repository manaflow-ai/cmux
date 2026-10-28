@testable import CmuxNextMobile
import Foundation
import Testing

/// The attach ticket's token comes from the system's secure generator without lending a pointer
/// (strict memory safety): 32 random bytes, base64url without padding, fresh on every call.
@Suite struct MobileAttachTokenTests {
    @Test func tokenIsThirtyTwoBytesOfBase64URL() {
        let token = MobileAttachTicket.randomToken()
        // 32 bytes are 43 base64 characters once the one `=` of padding is dropped.
        #expect(token.count == 43)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func tokensDoNotRepeat() {
        let tokens = Set((0..<64).map { _ in MobileAttachTicket.randomToken() })
        #expect(tokens.count == 64)
    }
}
