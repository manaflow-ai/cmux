/// Selects which keyboard dock implementation a terminal host mounts with.
///
/// The legacy notification+transform path is the shipping default on every
/// OS. The rebuilt single-constraint path is reachable two ways, both scoped
/// to iOS 26 and earlier because the rebuild misreads iOS 27's keyboard
/// frames: the remote `ios-keyboard-dock-rebuild-revert` kill switch, and the
/// DEBUG-only local override (Settings > Developer, or the UI-test forces).
/// Hosts evaluate this once at mount, so any input change applies when the
/// workspace is reopened.
public struct TerminalKeyboardDockPathSelection: Sendable, Equatable {
    /// The runtime OS major version (e.g. 26, 27).
    public let osMajorVersion: Int
    /// The remote kill switch reverting iOS ≤26 to the rebuilt path.
    public let remoteRebuildRevert: Bool
    /// DEBUG-only force pinning the legacy path regardless of OS.
    public let debugForceLegacy: Bool
    /// DEBUG-only force pinning the rebuilt path on iOS ≤26.
    public let debugForceRebuild: Bool

    /// Creates a selection from the runtime inputs a host snapshots at mount.
    ///
    /// - Parameters:
    ///   - osMajorVersion: The runtime OS major version.
    ///   - remoteRebuildRevert: The remote kill switch value.
    ///   - debugForceLegacy: DEBUG-only legacy pin (UI-test env force).
    ///   - debugForceRebuild: DEBUG-only rebuild pin (UI-test env force or
    ///     the Settings > Developer override).
    public init(
        osMajorVersion: Int,
        remoteRebuildRevert: Bool,
        debugForceLegacy: Bool = false,
        debugForceRebuild: Bool = false
    ) {
        self.osMajorVersion = osMajorVersion
        self.remoteRebuildRevert = remoteRebuildRevert
        self.debugForceLegacy = debugForceLegacy
        self.debugForceRebuild = debugForceRebuild
    }

    /// Whether the host uses the legacy notification+transform dock path.
    public var usesLegacyPath: Bool {
        if debugForceLegacy { return true }
        // The rebuild is unverified on iOS 27+ and misreads its keyboard
        // frames; no override may route those OS versions to it.
        if osMajorVersion >= 27 { return true }
        if debugForceRebuild { return false }
        return !remoteRebuildRevert
    }
}
