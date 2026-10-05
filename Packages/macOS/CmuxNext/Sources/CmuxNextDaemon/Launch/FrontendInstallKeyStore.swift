public import Foundation
import Security

/// Where the app keeps its `FrontendInstallKey`, one per tagged daemon
/// session. Only unsigned or ad-hoc development builds have one: a 0600 file
/// in the tag's 0700 state directory (the known DEV gap in identity.md).
/// A signed build has none: its daemon accepts only the code signature, so
/// a key would grant nothing, and no Keychain item or file is created.
public protocol FrontendInstallKeyStore: Sendable {
    /// The stored key, created on first use. Nil when it cannot be read or
    /// written: the app then proves nothing.
    func loadOrCreate() -> FrontendInstallKey?
}

public struct FrontendInstallKeyStores {
    public init() {}

    /// The store for this app process, or nil. `team` is this process's Team
    /// ID: a signed build gets no store, whatever sits in its state directory.
    public static func forApp(stateDirectory: URL?,
                              team: String? = CodeSigningTeam.current()) -> (any FrontendInstallKeyStore)? {
        guard team == nil, let stateDirectory else { return nil }
        return FileFrontendInstallKeyStore(file: stateDirectory.appendingPathComponent("frontend-install-key"))
    }
}

/// This process's code signing Team ID, if it has one.
public struct CodeSigningTeam {
    public init() {}

    public static func current() -> String? {
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
