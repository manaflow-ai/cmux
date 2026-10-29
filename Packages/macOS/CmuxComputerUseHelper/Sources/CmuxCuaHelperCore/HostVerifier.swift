// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Security

/// Whether the process on the other end of the control pipe is the cmux app.
public enum HostVerification: Sendable, Equatable {
    case verified
    case unverified(String)
}

/// Checks the controlling host once, at startup. Until a host is verified,
/// the helper trusts nothing it says about consent and runs no `call`.
public protocol HostVerifying: Sendable {
    func verify() -> HostVerification
}

/// The parent process (the launcher, which holds the control pipe) must be
/// a cmux app signed by cmux's team. An ad hoc or unsigned launcher, another
/// team's code, or a team-signed non-app binary is unverified. There is no
/// environment or argument override.
public struct ParentProcessVerifier: HostVerifying {
    public static let teamRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "7WLXT3NR37""#

    public init() {}

    public func verify() -> HostVerification {
        let parent = getppid()
        guard parent > 1 else { return .unverified("no parent process (launched by launchd, not the cmux app)") }
        let result = Self.check(pid: parent)
        // A pid cannot be reused while it is still our parent; if the parent
        // exited during the check we were reparented and the answer is void.
        guard getppid() == parent else { return .unverified("the parent process exited during the check") }
        return result
    }

    static func check(pid: pid_t) -> HostVerification {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else {
            return .unverified("cannot read the parent process's code (pid \(pid))")
        }
        guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else {
            return .unverified("the parent's code signature is not valid")
        }
        guard satisfies(guest, "anchor apple generic") else {
            return .unverified("not Apple-signed (ad hoc or unsigned)")
        }
        guard satisfies(guest, teamRequirement) else { return .unverified("not signed by cmux's team") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(guest, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String else {
            return .unverified("cannot read the parent's signing identifier")
        }
        guard isCmuxAppIdentifier(identifier) else {
            return .unverified("signing identifier \(identifier) is not a cmux app")
        }
        return .verified
    }

    /// `com.cmuxterm.app`, or `com.cmuxterm.app.` followed by at least one
    /// character (nightly, debug.<tag>, ...).
    static func isCmuxAppIdentifier(_ identifier: String) -> Bool {
        let base = "com.cmuxterm.app"
        guard identifier.hasPrefix(base) else { return false }
        let rest = identifier.dropFirst(base.count)
        return rest.isEmpty || (rest.hasPrefix(".") && rest.count > 1)
    }

    private static func satisfies(_ code: SecCode, _ requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}
