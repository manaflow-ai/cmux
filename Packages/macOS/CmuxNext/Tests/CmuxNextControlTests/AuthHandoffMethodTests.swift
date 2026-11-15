import CmuxNextActions
import CmuxNextCloud
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `auth.handoff.mint` / `auth.handoff.redeem` (`cmux auth handoff`): params, answers and refusals.
@Suite struct AuthHandoffMethodTests {
    private let code = "cmh_team_0123456789abcdefabcd.ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk_-0123"

    @Test func onlyTheMintedCodeShapeIsTaken() throws {
        #expect(try ControlMethod.authHandoffCode(["code": .string(code)]) == code)
        for bad in ["", "cmh_team_0123456789abcdefabcd", code + "x", code.replacingOccurrences(of: "team_0", with: "team_A"),
                    code.replacingOccurrences(of: "ABC", with: "A C"), code.replacingOccurrences(of: "cmh_", with: "cmj_")] {
            #expect(throws: ControlError.self) { try ControlMethod.authHandoffCode(["code": .string(bad)]) }
        }
        #expect(throws: ControlError.self) { try ControlMethod.authHandoffCode([:]) }
        #expect(throws: ControlError.self) { try ControlMethod.authHandoffCode(["code": .number(1)]) }
    }

    @Test func theDeviceIsOptionalShortAndPrintable() throws {
        #expect(try ControlMethod.authHandoffDevice([:]) == nil)
        #expect(try ControlMethod.authHandoffDevice(["device": .null]) == nil)
        #expect(try ControlMethod.authHandoffDevice(["device": .string("  ")]) == nil)
        #expect(try ControlMethod.authHandoffDevice(["device": .string(" air-blue ")]) == "air-blue")
        #expect(throws: ControlError.self) { try ControlMethod.authHandoffDevice(["device": .string(String(repeating: "x", count: 65))]) }
        #expect(throws: ControlError.self) { try ControlMethod.authHandoffDevice(["device": .string("a\nb")]) }
        #expect(throws: ControlError.self) { try ControlMethod.authHandoffDevice(["device": .number(3)]) }
    }

    @Test func theAnswersCarryNoToken() {
        let mint = ControlMethod.authHandoffMintReply(CloudAuthHandoff.Minted(code: code, expiresAt: 1_763_100_000_000, user: "user_1", email: "a@b.c", device: nil))
        #expect(mint["code"]?.stringValue == code)
        #expect(mint["expires_at"]?.intValue == 1_763_100_000_000)
        #expect(mint["device"]?.isNull == true)
        let redeemed = ControlMethod.authHandoffRedeemReply(CloudAuthHandoff.Redeemed(alreadySignedIn: false, accessToken: "secret-access", refreshToken: "secret-refresh", user: "user_1", stackUser: "s1", email: "a@b.c", device: "cmux16"))
        #expect(redeemed["signed_in"] == .bool(true))
        #expect(redeemed["already_signed_in"] == .bool(false))
        #expect(redeemed["access_token"] == nil)
        #expect(redeemed["refresh_token"] == nil)
        #expect(!"\(redeemed)".contains("secret-"))
        // A minted code never shows in a description (a log or crash report).
        #expect(!CloudAuthHandoff.Minted(code: code, expiresAt: 0, user: "u", email: nil, device: nil).description.contains("ABCDEF"))
    }

    @Test func refusalsKeepTheCodeTheCLIMapsToAnExitCode() {
        for refusal in ["handoff_invalid", "other_user", "not_signed_in", "sso_required", "rate_limited", "invalid_params", "unavailable"] {
            let error = ControlMethod.authHandoffError(refusal)
            #expect(error.code == refusal)
            #expect(!error.message.isEmpty)
        }
    }

    @Test func bothMethodsAreOffWithCloud() {
        #expect(ActionFeature(controlMethod: "auth.handoff.mint") == .cloud)
        #expect(ActionFeature(controlMethod: "auth.handoff.redeem") == .cloud)
    }
}
