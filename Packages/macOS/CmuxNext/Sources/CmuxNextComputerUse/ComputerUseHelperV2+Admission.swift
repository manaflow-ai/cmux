// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Which code the helper socket admits as an acpmux bridge, and the signing
/// facts it is built from: this app's team, an executable's signing
/// identifier and its cdhash. The helper checks every bridge's live audit
/// token against the requirement (release) or the cdhash (ad-hoc
/// development) that ``acpmuxAdmission(executable:teamIdentifier:identifier:hash:)``
/// returns. Moved out of the launcher unchanged so that the risk tier can
/// grade this trust decision on its own.
extension ComputerUseHelperV2 {
    /// This app's signing team. Ad-hoc development builds have no team and
    /// retain the same-executable-path peer rule.
    nonisolated static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let info = info as? [String: Any] else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }()

    /// The code-signing identifier read from an executable. A raced path can
    /// at worst produce a requirement the real helper does not satisfy: the
    /// live audit-token check still requires this app's team.
    nonisolated static func codeIdentifier(_ executable: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoIdentifier as String] as? String
    }

    /// Release helpers check every bridge's live audit token against its exact
    /// identifier and this app's team. Only ad-hoc development uses a
    /// mutable-path cdhash.
    nonisolated static func acpmuxAdmission(executable: URL, teamIdentifier: String? = ownTeam,
                                            identifier: (URL) -> String? = codeIdentifier,
                                            hash: (URL) -> Data? = cdhash)
        -> (hashes: [String], requirement: String?) {
        if let teamIdentifier {
            let plain = { (text: String) in
                !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            }
            guard plain(teamIdentifier), let identifier = identifier(executable), plain(identifier) else { return ([], nil) }
            return ([], "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\"")
        }
        return (hash(executable).map { [hex($0)] } ?? [], nil)
    }

    /// The cdhash of a signed executable on disk.
    nonisolated static func cdhash(_ url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoUnique as String] as? Data
    }
}
