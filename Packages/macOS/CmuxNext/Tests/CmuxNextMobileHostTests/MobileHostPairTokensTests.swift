import CmuxNextMobile
@testable import CmuxNextMobileHost
import CryptoKit
import Foundation
import Testing

/// This Mac's pairing code: a single-use, short-lived pre-approval bound to this Mac's device id
/// that stands in for the person's Allow, never for the account check.
@Suite struct MobileHostPairTokensTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func request(token: String?) -> MobileHostPairRequest {
        MobileHostPairRequest(phoneDeviceID: "phone-1", name: "iPhone", identityKey: "04" + String(repeating: "aa", count: 64),
                              approvalKey: "04" + String(repeating: "bb", count: 64), pairToken: token)
    }

    @Test func aTokenPairsOnceThenIsBurnt() {
        var tokens = MobileHostPairTokens()
        let minted = tokens.mint(macDeviceID: "mac-1", now: Self.now)
        #expect(minted.token.count >= 16)
        #expect(minted.expiresAt == Self.now.addingTimeInterval(MobileHostPairTokens.lifetime))
        #expect(tokens.redeem(minted.token, macDeviceID: "mac-1", now: Self.now.addingTimeInterval(10)))
        #expect(!tokens.redeem(minted.token, macDeviceID: "mac-1", now: Self.now.addingTimeInterval(11)), "used twice")
    }

    @Test func anExpiredWrongMacUnknownOrRevokedTokenPairsNothing() {
        var tokens = MobileHostPairTokens()
        let minted = tokens.mint(macDeviceID: "mac-1", now: Self.now)
        #expect(!tokens.redeem(minted.token, macDeviceID: "mac-1", now: minted.expiresAt), "expired")
        let fresh = tokens.mint(macDeviceID: "mac-1", now: Self.now)
        #expect(!tokens.redeem(fresh.token, macDeviceID: "mac-2", now: Self.now), "another Mac id")
        #expect(!tokens.redeem(fresh.token, macDeviceID: nil, now: Self.now), "no Mac id yet")
        #expect(!tokens.redeem(nil, macDeviceID: "mac-1", now: Self.now))
        #expect(!tokens.redeem(fresh.token + "x", macDeviceID: "mac-1", now: Self.now))
        #expect(!tokens.redeem(String(fresh.token.dropLast()), macDeviceID: "mac-1", now: Self.now))
        let newer = tokens.mint(macDeviceID: "mac-1", now: Self.now)
        #expect(!tokens.redeem(fresh.token, macDeviceID: "mac-1", now: Self.now), "a new code revokes the old one")
        tokens.revoke()
        #expect(!tokens.redeem(newer.token, macDeviceID: "mac-1", now: Self.now), "revoked")
    }

    @Test func theShownTokenIsReusedUntilAMinuteBeforeItExpires() {
        var tokens = MobileHostPairTokens()
        let first = tokens.current(macDeviceID: "mac-1", now: Self.now)
        #expect(tokens.current(macDeviceID: "mac-1", now: Self.now.addingTimeInterval(200)) == first)
        let next = tokens.current(macDeviceID: "mac-1", now: Self.now.addingTimeInterval(MobileHostPairTokens.lifetime - 30))
        #expect(next.token != first.token)
        #expect(tokens.current(macDeviceID: "mac-2", now: Self.now).token != next.token, "another Mac id mints its own")
    }

    /// The token stands in for the person's Allow only for the signed-in user's own list.
    @Test func onlyTheSignedInUsersListIsPreapproved() {
        var tokens = MobileHostPairTokens()
        let token = tokens.mint(macDeviceID: "mac-1", now: Self.now).token
        #expect(!IPhoneHostService.redeems(Self.request(token: nil), tokens: &tokens, macDeviceID: "mac-1",
                                           pairedUserID: "u1", accountUserID: "u1", now: Self.now))
        #expect(!IPhoneHostService.redeems(Self.request(token: token), tokens: &tokens, macDeviceID: "mac-1",
                                           pairedUserID: "u1", accountUserID: nil, now: Self.now))
        #expect(!IPhoneHostService.redeems(Self.request(token: token), tokens: &tokens, macDeviceID: "mac-1",
                                           pairedUserID: "u1", accountUserID: "u2", now: Self.now))
        #expect(IPhoneHostService.redeems(Self.request(token: token), tokens: &tokens, macDeviceID: "mac-1",
                                          pairedUserID: "u1", accountUserID: "u1", now: Self.now))
        #expect(!IPhoneHostService.redeems(Self.request(token: token), tokens: &tokens, macDeviceID: "mac-1",
                                           pairedUserID: "u1", accountUserID: "u1", now: Self.now), "burnt")
    }

    @Test func theCodeNamesThisMacItsTeamTheTokenAndItsKey() throws {
        let key = Data([0x04] + [UInt8](repeating: 7, count: 64))
        let invite = MobileHostPairInvite(macDeviceID: "mac-1", teamID: "team 1", macName: "Studio & Co", token: "tok_en-1234567890",
                                          macPublicKey: key, expiresAt: Self.now)
        let components = try #require(URLComponents(string: invite.url))
        #expect(components.scheme == "cmux-next")
        #expect(components.host == "pair")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["mac"] == "mac-1")
        #expect(items["team"] == "team 1")
        #expect(items["name"] == "Studio & Co")
        #expect(items["t"] == "tok_en-1234567890")
        let hash = Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(items["k"] == hash)
    }

    @Test func hostdForwardsTheTokenWithTheRequest() throws {
        let line = #"{"type":"pair_request","phone_device_id":"p","name":"n","identity_key":"04","approval_key":"04","pair_token":"abcDEF-_0123456789"}"#
        guard case .pairRequest(let request)? = MobileHostEvent(line: Substring(line)) else {
            Issue.record("not a pair request")
            return
        }
        #expect(request.pairToken == "abcDEF-_0123456789")
        let plain = #"{"type":"pair_request","phone_device_id":"p","name":"n","identity_key":"04","approval_key":"04"}"#
        guard case .pairRequest(let without)? = MobileHostEvent(line: Substring(plain)) else {
            Issue.record("not a pair request")
            return
        }
        #expect(without.pairToken == nil)
    }
}
