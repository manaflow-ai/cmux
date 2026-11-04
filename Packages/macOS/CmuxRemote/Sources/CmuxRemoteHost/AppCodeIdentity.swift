// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import Darwin
import Foundation
import Security

/// The signing identifier of a socket peer's running code (for the cmux app, its bundle id),
/// read by the audit token the kernel recorded for the connection: a valid signature, and an
/// identifier that the same running code satisfies as a requirement. Nil when any step fails.
enum AppCodeIdentity {
    static func signingIdentifier(of peer: SocketPeer) -> String? {
        var token = peer.token
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(guest, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String,
              isPlain(identifier) else { return nil }
        // Only [A-Za-z0-9._-]: safe to quote in a requirement.
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else { return nil }
        return identifier
    }

    static func isPlain(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 255
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }
}
