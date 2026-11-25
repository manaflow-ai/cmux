public import Darwin
import Foundation
import Security

/// Reads who signed the code of a peer process, named by its audit token. Injected into
/// ``SessionHandoffPolicy`` so tests can stand in for the Security framework.
public protocol SessionHandoffCodeChecking: Sendable {
    /// The peer's signing identifier when its code is validly signed by `teamIdentifier` through an
    /// Apple-issued certificate, runs under the hardened runtime and may not be debugged
    /// (`get-task-allow`), else nil. Ad hoc and unsigned code, another team's code, debuggable code and a
    /// process that is gone all answer nil.
    func signingIdentifier(of token: audit_token_t, teamIdentifier: String) -> String?
}

/// The Security framework check: the guest code for the audit token, a valid signature, an Apple
/// anchor, the team in the leaf certificate's OU, the hardened runtime without `get-task-allow` (so no
/// debugger or injected library can sit in the process), and the signing identifier bound to that same code.
public struct SessionHandoffCodeCheck: SessionHandoffCodeChecking {
    /// Creates the check.
    public init() {}

    public func signingIdentifier(of token: audit_token_t, teamIdentifier: String) -> String? {
        // The team id goes into a requirement string: allow only its own alphabet.
        guard !teamIdentifier.isEmpty, teamIdentifier.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return nil
        }
        var token = token
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &guest)
            == errSecSuccess, let guest else { return nil }
        let team = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        guard Self.satisfies(guest, team) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(guest, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String,
              let signing = info as NSDictionary?,
              Self.isHardened(signing),
              !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return nil
        }
        // The identifier read from the signing information must be the one the running code satisfies.
        guard Self.satisfies(guest, "identifier \"\(identifier)\" and \(team)") else { return nil }
        return identifier
    }

    /// Hardened runtime on, and no `get-task-allow` entitlement.
    static func isHardened(_ signing: NSDictionary) -> Bool {
        let flags = (signing.object(forKey: kSecCodeInfoFlags) as? NSNumber)?.uint32Value ?? 0
        guard flags & SecCodeSignatureFlags.runtime.rawValue != 0 else { return false }
        let entitlements = signing.object(forKey: kSecCodeInfoEntitlementsDict) as? NSDictionary
        return (entitlements?.object(forKey: "com.apple.security.get-task-allow") as? Bool) != true
    }

    /// `SecCodeCheckValidity` with a requirement: the signature is valid and satisfies it.
    private static func satisfies(_ code: SecCode, _ requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}
