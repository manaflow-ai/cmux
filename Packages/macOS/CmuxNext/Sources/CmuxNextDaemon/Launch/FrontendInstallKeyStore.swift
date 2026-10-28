public import Foundation
import CmuxNextCompat

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
    /// The app's launch passes the team it read on its system lane
    /// (`DaemonLauncher.forApp`).
    public static func forApp(stateDirectory: URL?,
                              team: String? = CodeSigningTeam.current()) -> (any FrontendInstallKeyStore)? {
        guard team == nil, let stateDirectory else { return nil }
        return FileFrontendInstallKeyStore(file: stateDirectory.appendingPathComponent("frontend-install-key"))
    }
}

/// This process's code signing Team ID, if it has one.
public struct CodeSigningTeam {
    public init() {}

    /// Read once per process (``SigningTeamInstall/process``): the signature of a running process does
    /// not change. The app's first reads are on its system lane at launch (the daemon prestart and the
    /// signing team load, both posted from `main`); the daemon prestart takes the team from there by
    /// parameter. Before that load a read asks securityd itself: call it off the main thread, or after launch.
    public static func current() -> String? { SigningTeamInstall.process.team }
}
