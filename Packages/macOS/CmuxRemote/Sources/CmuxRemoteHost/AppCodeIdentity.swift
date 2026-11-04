// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxCuaHelperCore
import CmuxRemoteWire
import Darwin
import Foundation
import Security

/// The signing identifier of a socket peer's running code (for the cmux app, its bundle id),
/// read by the audit token the kernel recorded for the connection: a valid signature, and an
/// identifier that the same running code satisfies as a requirement. Nil when any step fails.
///
/// A release cmux Remote also requires that code to be Apple-anchored and signed by cmux's team,
/// and to be one of cmux's main apps: the requirement and list ``CmuxAppCodeCheck`` holds for the
/// cmux app. The DEV host (`com.cmuxterm.remote.dev`) serves tagged DEV apps, which are ad hoc
/// signed (no team to require), so it binds the identifier alone (review 2 #12).
enum AppCodeIdentity {
    enum Policy: Equatable {
        /// Apple anchor, cmux's team and a main-app identifier.
        case release
        /// The identifier alone (ad hoc signed DEV apps).
        case development

        /// The DEV host's bundle id; any other host is release (a renamed or unknown bundle fails closed).
        static let developmentHost = "com.cmuxterm.remote.dev"

        /// The policy of a host whose own bundle id is `bundleIdentifier`. An unbundled build
        /// (nil: `swift test`, a bare executable) is the DEV host, as main.swift names it.
        static func forHost(bundleIdentifier: String?) -> Policy {
            guard let bundleIdentifier else { return .development }
            return bundleIdentifier == developmentHost ? .development : .release
        }

        /// This process's policy.
        static let current = forHost(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func signingIdentifier(of peer: SocketPeer, policy: Policy = .current) -> String? {
        var token = peer.token
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(guest, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String,
              admits(identifier: identifier, policy: policy) else { return nil }
        // Only [A-Za-z0-9._-]: safe to quote in a requirement.
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement(identifier: identifier, policy: policy) as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else { return nil }
        return identifier
    }

    /// The requirement the peer's running code must satisfy for `identifier`.
    static func requirement(identifier: String, policy: Policy) -> String {
        switch policy {
        case .release: "identifier \"\(identifier)\" and \(CmuxAppCodeCheck.requirement)"
        case .development: "identifier \"\(identifier)\""
        }
    }

    /// Whether `identifier` may be a client: plain text, and under release one of cmux's main apps.
    static func admits(identifier: String, policy: Policy) -> Bool {
        guard isPlain(identifier) else { return false }
        return policy == .development || CmuxAppCodeCheck.isMainApp(identifier)
    }

    static func isPlain(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 255
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }
}
