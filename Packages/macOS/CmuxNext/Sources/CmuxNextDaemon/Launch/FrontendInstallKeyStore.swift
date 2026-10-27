public import CmuxNextWakeups
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
/// root injects: on macOS `SigningTeamInstall`; on Linux no team, since an ELF binary carries no code
/// signature, so every Linux build gets the 0600 file. The launchers never ask for the signature themselves,
/// and never on their caller's thread: they take ``read(stateDirectory:on:)``, which reads the team and the
/// key on lanes.
public struct FrontendInstallKeyStores: Sendable {
    private let team: @Sendable () -> String?

    /// - Parameter team: This process's code signing Team ID, nil for an unsigned or ad-hoc build. It may block
    ///   (securityd): it is called only on a lane (``read(stateDirectory:on:)``) or by ``forApp(stateDirectory:)``'s
    ///   caller, never here.
    public init(team: @escaping @Sendable () -> String?) {
        self.team = team
    }

    /// The store for this app process, or nil: a signed build gets no store, whatever sits in its state
    /// directory. It calls `team` on the caller's thread: call it on a lane.
    public func forApp(stateDirectory: URL?) -> (any FrontendInstallKeyStore)? {
        guard let stateDirectory, !isSigned() else { return nil }
        return FileFrontendInstallKeyStore(file: Self.keyFile(in: stateDirectory))
    }

    /// The install key of this app process for `stateDirectory`, read once on `work`'s lanes (the team on the
    /// system lane, the key file on the files lane), starting now; ``FrontendInstallKeySource/noKey`` without a
    /// state directory. Nothing blocks the caller, so a launcher built on the main thread takes it.
    public func read(stateDirectory: URL?, on work: BackgroundWork) -> FrontendInstallKeySource {
        guard let stateDirectory else { return .noKey }
        return .reading(self, stateDirectory: stateDirectory, on: work)
    }

    /// Whether this process is Team-signed. It may ask securityd.
    func isSigned() -> Bool {
        team() != nil
    }

    /// Where an unsigned build keeps its key in `stateDirectory`.
    static func keyFile(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("frontend-install-key")
    }
}
