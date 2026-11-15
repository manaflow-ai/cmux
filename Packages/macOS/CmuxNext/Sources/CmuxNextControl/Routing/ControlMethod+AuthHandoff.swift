public import CmuxNextActions
public import CmuxNextCloud
import CmuxNextSettings
import Foundation

extension ControlMethod {
    /// `auth.handoff.mint {device?}` and `auth.handoff.redeem {code, device?}` (`cmux auth handoff`,
    /// cmux-tui `cli/auth_handoff.rs`; cmux-api `auth-handoff.ts`). The app mints with its own human Stack
    /// session and redeems into its own session store (``CloudAuth/mintHandoff(device:api:)``,
    /// ``CloudAuth/redeemHandoff(code:device:api:)``): no token crosses this socket, only the one-time code
    /// (out on mint, in on redeem). Off with Cloud. Nothing here logs a code.
    public static func authHandoff(
        disabledFeatures: @escaping @MainActor @Sendable () -> Set<ActionFeature>,
        auth: CloudAuth,
        api: CloudAuthHandoff
    ) -> [ControlMethod] {
        [
            .async("auth.handoff.mint") { call in
                let disabled = await MainActor.run { disabledFeatures() }
                if let refusal = ControlError.policyRefusal("auth.handoff.mint", disabled: disabled) { throw refusal }
                let device = try authHandoffDevice(call.params)
                do {
                    return authHandoffMintReply(try await auth.mintHandoff(device: device, api: api))
                } catch let refusal as CloudAuthHandoff.Refusal {
                    throw authHandoffError(refusal.code)
                }
            }.withDeadline(.fixed(.seconds(25))),
            .async("auth.handoff.redeem") { call in
                let disabled = await MainActor.run { disabledFeatures() }
                if let refusal = ControlError.policyRefusal("auth.handoff.redeem", disabled: disabled) { throw refusal }
                let code = try authHandoffCode(call.params)
                let device = try authHandoffDevice(call.params)
                do {
                    return authHandoffRedeemReply(try await auth.redeemHandoff(code: code, device: device, api: api))
                } catch let refusal as CloudAuthHandoff.Refusal {
                    throw authHandoffError(refusal.code)
                }
            }.withDeadline(.fixed(.seconds(25))),
        ]
    }

    /// The optional `device` name: a string of at most 64 printable characters; empty reads as absent.
    static func authHandoffDevice(_ params: [String: JSONValue]) throws -> String? {
        guard let raw = params["device"], !raw.isNull else { return nil }
        guard let text = raw.stringValue?.trimmingCharacters(in: .whitespaces) else { throw authHandoffError("invalid_params") }
        if text.isEmpty { return nil }
        guard text.count <= 64, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw authHandoffError("invalid_params")
        }
        return text
    }

    /// The `code`: exactly the shape cmux-api mints (`cmh_team_<20>.<43 base64url>`), or `invalid_params`.
    static func authHandoffCode(_ params: [String: JSONValue]) throws -> String {
        guard let code = params["code"]?.stringValue, isAuthHandoffCode(code) else { throw authHandoffError("invalid_params") }
        return code
    }

    static func isAuthHandoffCode(_ code: String) -> Bool {
        guard code.hasPrefix("cmh_team_") else { return false }
        let parts = code.dropFirst("cmh_team_".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let team = parts.first, let secret = parts.last, team.utf8.count == 20, secret.utf8.count == 43 else {
            return false
        }
        let lowerOrDigit = { (b: UInt8) in (0x30 ... 0x39).contains(b) || (0x61 ... 0x7A).contains(b) }
        let base64url = { (b: UInt8) in lowerOrDigit(b) || (0x41 ... 0x5A).contains(b) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") }
        return team.utf8.allSatisfy(lowerOrDigit) && secret.utf8.allSatisfy(base64url)
    }

    static func authHandoffMintReply(_ minted: CloudAuthHandoff.Minted) -> JSONValue {
        .object([
            "code": .string(minted.code),
            "expires_at": .number(Double(minted.expiresAt)),
            "user": .string(minted.user),
            "email": minted.email.map(JSONValue.string) ?? .null,
            "device": minted.device.map(JSONValue.string) ?? .null,
        ])
    }

    /// The redeem answer: who this app is signed in as now; never a token.
    static func authHandoffRedeemReply(_ redeemed: CloudAuthHandoff.Redeemed) -> JSONValue {
        .object([
            "signed_in": .bool(true),
            "already_signed_in": .bool(redeemed.alreadySignedIn),
            "user": .string(redeemed.user),
            "email": redeemed.email.map(JSONValue.string) ?? .null,
            "device": redeemed.device.map(JSONValue.string) ?? .null,
        ])
    }

    /// A refusal as this socket's error; `code` is what the CLI maps to its exit code (`handoff_invalid`,
    /// `other_user`, `not_signed_in`, `sso_required`, `rate_limited`, `invalid_params`, `unavailable`). The CLI
    /// shows its own localized words for each code; these English ones are for other callers.
    static func authHandoffError(_ code: String) -> ControlError {
        let message = switch code {
        case "handoff_invalid": "The hand-off code expired, was used, or is not a code. Mint a new one."
        case "other_user": "This Mac's cmux is signed in as another account. Sign out there first; the code was not used."
        case "not_signed_in": "Sign in to cmux on this Mac first."
        case "sso_required": "Your organization requires sign-in with its SSO on each device."
        case "rate_limited": "Too many hand-off codes; try again in a few minutes."
        case "invalid_params": "auth.handoff takes a code of the shape cmux mints and a device name of at most 64 characters."
        default: "cmux could not be reached. Try again in a moment."
        }
        return ControlError(code: code, message: message)
    }
}
