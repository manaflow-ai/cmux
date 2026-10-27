public import Foundation

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

/// Picks the app's `FrontendInstallKeyStore` from this process's code signing team, which the composition
/// root injects: on macOS `SigningTeamInstall`, read once on the system lane; on Linux no team, since an
/// ELF binary carries no code signature, so every Linux build gets the 0600 file. The launchers never ask
/// for the signature themselves.
public struct FrontendInstallKeyStores: Sendable {
    private let team: @Sendable () -> String?

    /// - Parameter team: This process's code signing Team ID, nil for an unsigned or ad-hoc build. Read when a
    ///   launcher picks its store, never here.
    public init(team: @escaping @Sendable () -> String?) {
        self.team = team
    }

    /// The store for this app process, or nil: a signed build gets no store, whatever sits in its state
    /// directory.
    public func forApp(stateDirectory: URL?) -> (any FrontendInstallKeyStore)? {
        guard let stateDirectory, team() == nil else { return nil }
        return FileFrontendInstallKeyStore(file: stateDirectory.appendingPathComponent("frontend-install-key"))
    }
}
