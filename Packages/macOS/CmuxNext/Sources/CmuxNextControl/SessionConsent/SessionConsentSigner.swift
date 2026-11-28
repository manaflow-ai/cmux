public import Darwin
import Foundation
import Security

/// Who signed a peer process's code, as `auth.session.request` reads it: any valid signature, ad hoc
/// included. Rust decides what the signer may ask for (``SessionConsentRules``).
public struct SessionConsentSigner: Sendable, Equatable {
    /// The signing identifier the valid signature carries.
    public var identifier: String
    /// The team, when the signature chains to an Apple certificate of one; nil for ad hoc code.
    public var teamID: String?
    /// The code's path on disk.
    public var path: String?

    public init(identifier: String, teamID: String?, path: String?) {
        self.identifier = identifier
        self.teamID = teamID
        self.path = path
    }
}

/// Reads ``SessionConsentSigner`` for an audit token. Injected into ``SessionConsentResponder`` and
/// ``SessionConsentClient`` so tests can stand in for the Security framework.
public protocol SessionConsentSignerReading: Sendable {
    /// The peer's signer when its code has a valid signature (ad hoc included), else nil: unsigned code, a
    /// broken signature or a process that is gone.
    func signer(of token: audit_token_t) -> SessionConsentSigner?
}

/// The Security framework read: the guest code for the audit token, a valid signature, and the signing
/// identifier bound to that same code; the team only when an Apple-issued leaf certificate carries it.
public struct SessionConsentCodeCheck: SessionConsentSignerReading {
    /// Creates the check.
    public init() {}

    public func signer(of token: audit_token_t) -> SessionConsentSigner? {
        var token = token
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &guest)
            == errSecSuccess, let guest else { return nil }
        // A valid signature of any kind: the code's pages match its code directory.
        guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        let staticCode = unsafeBitCast(guest, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as NSDictionary?,
              let identifier = fields.object(forKey: kSecCodeInfoIdentifier) as? String,
              !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return nil
        }
        // The identifier read must be the one the running code satisfies.
        guard Self.satisfiesRequirement(guest, "identifier \"\(identifier)\"") else { return nil }
        // A team only when the leaf certificate is Apple-issued for it (ad hoc code has none).
        var team: String?
        if let claimed = fields.object(forKey: kSecCodeInfoTeamIdentifier) as? String, !claimed.isEmpty,
           claimed.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
           Self.satisfiesRequirement(guest, "anchor apple generic and certificate leaf[subject.OU] = \"\(claimed)\"") {
            team = claimed
        }
        var url: CFURL?
        let path = SecCodeCopyPath(staticCode, [], &url) == errSecSuccess ? (url as URL?)?.path : nil
        return SessionConsentSigner(identifier: identifier, teamID: team, path: path)
    }

    private static func satisfiesRequirement(_ code: SecCode, _ requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}
