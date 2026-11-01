// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Security

/// Whether a host consent connection's peer is the cmux app.
public enum HostVerification: Sendable, Equatable {
    case verified
    case unverified(String)
}

/// Checks the peer of one host consent connection, by the audit token the
/// kernel recorded for that connection. The token carries the pid version,
/// so a process that exec'd after connecting does not match it.
public protocol HostCodeChecking: Sendable {
    func check(_ token: audit_token_t) -> HostVerification
}

/// The cmux main apps a consent answer may come from. Helper bundles are
/// never on it. The same list is used by legacy serve and the app.
extension CmuxAppCodeCheck {
    public static let teamIdentifier = "7WLXT3NR37"
    public static let requirement = #"anchor apple generic and certificate leaf[subject.OU] = "7WLXT3NR37""#

    /// Exact main-app bundle ids.
    public static let identifiers: Set<String> = [
        "com.cmuxterm.app", // stable (cmux.xcodeproj Release; verify-app-bundle-channel-metadata.sh stable)
        "com.cmuxterm.app.nightly", // NIGHTLY (verify-app-bundle-channel-metadata.sh nightly)
        "com.cmuxterm.app.nightly.cmux-next", // cmux NEXT nightly (verify-app-bundle-channel-metadata.sh next)
        "com.cmuxterm.app.nightly.cmux-next-stable", // cmux NEXT Stable (verify-app-bundle-channel-metadata.sh next-stable)
        "com.cmuxterm.app.rc", // RC (verify-app-bundle-channel-metadata.sh rc)
        "com.cmuxterm.app.debug", // DEV, untagged (cmux.xcodeproj Debug; scripts/reload.sh)
        "com.cmuxterm.app.staging", // staging, untagged (scripts/reloads.sh)
    ]

    /// Tagged builds: the prefix, then a tag of `[a-z0-9]+` segments joined
    /// by "." (scripts/reload.sh and scripts/reloads.sh, `sanitize_bundle`;
    /// the dev daily `com.cmuxterm.app.debug.next` is one).
    public static let taggedPrefixes = ["com.cmuxterm.app.debug.", "com.cmuxterm.app.staging."]

    /// Never a main app, whatever else matches: the Computer Use helpers
    /// (com.cmuxterm.cua, com.cmuxterm.cua.dev, com.cmuxterm.app.computer-use)
    /// and any other helper.
    static let helperMarkers = ["cua", "computer-use", "helper"]

    public static func isMainApp(_ identifier: String) -> Bool {
        guard !helperMarkers.contains(where: { identifier.contains($0) }) else { return false }
        if identifiers.contains(identifier) { return true }
        return taggedPrefixes.contains { prefix in
            guard identifier.hasPrefix(prefix) else { return false }
            let segments = identifier.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
            return segments.allSatisfy { segment in
                !segment.isEmpty && segment.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
            }
        }
    }
}

/// The real check, in steps that say why a peer fails: the peer's code by
/// audit token, a valid signature, Apple-anchored, cmux's team, then a
/// main-app identifier bound to that same code.
public struct CmuxAppCodeCheck: HostCodeChecking {
    public init() {}

    public func check(_ token: audit_token_t) -> HostVerification {
        var token = token
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [],
                                             &guest) == errSecSuccess, let guest else {
            return .unverified("cannot read the peer's code (it may have exited or exec'd)")
        }
        guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else {
            return .unverified("the peer's code signature is not valid")
        }
        guard Self.satisfies(guest, "anchor apple generic") else {
            return .unverified("not Apple-signed (ad hoc or unsigned)")
        }
        guard Self.satisfies(guest, Self.requirement) else { return .unverified("not signed by cmux's team") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(guest, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String else {
            return .unverified("cannot read the peer's signing identifier")
        }
        guard Self.isMainApp(identifier) else {
            return .unverified("signing identifier \(identifier) is not a cmux app")
        }
        // isMainApp admits only [a-z0-9.-]; the identifier is safe to quote.
        guard Self.satisfies(guest, "identifier \"\(identifier)\" and \(Self.requirement)") else {
            return .unverified("signing identifier \(identifier) does not match the running code")
        }
        return .verified
    }

    private static func satisfies(_ code: SecCode, _ requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}
