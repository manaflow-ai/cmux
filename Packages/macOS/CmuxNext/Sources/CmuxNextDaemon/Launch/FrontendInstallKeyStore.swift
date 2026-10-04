public import Foundation
import Security

/// Where the app keeps its `FrontendInstallKey`, one per daemon session.
///
/// - Signed builds (a Team ID): a generic-password item in the login
///   Keychain, `<bundle id>.frontend-install-key` / `<session>`, this device
///   only. Its default access list trusts only the app that created it (its
///   designated requirement: bundle id and team), so another process of the
///   user cannot read it without a prompt; the app itself never shows one
///   (`interactionNotAllowed`), it goes without the key instead.
/// - Unsigned or ad-hoc development builds: a 0600 file in the tag's 0700
///   state directory. The Keychain gives an ad-hoc build no protection
///   either (and would prompt on every rebuild); this is the known DEV gap
///   in identity.md.
public protocol FrontendInstallKeyStore: Sendable {
    /// The stored key, created on first use. Nil when it cannot be read
    /// without user interaction or written: the app then proves nothing.
    func loadOrCreate() -> FrontendInstallKey?
}

public enum FrontendInstallKeyStores {
    /// The store for this app process (see `FrontendInstallKeyStore`).
    public static func forApp(session: String, stateDirectory: URL?, bundleID: String?) -> (any FrontendInstallKeyStore)? {
        if CodeSigningTeam.current() != nil {
            let service = "\(bundleID?.isEmpty == false ? bundleID ?? "" : "com.cmuxterm.app").frontend-install-key"
            return KeychainFrontendInstallKeyStore(service: service, account: session)
        }
        guard let stateDirectory else { return nil }
        return FileFrontendInstallKeyStore(file: stateDirectory.appendingPathComponent("frontend-install-key"))
    }
}

/// This process's code signing Team ID, if it has one.
enum CodeSigningTeam {
    static func current() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
