/// Which installed Chromium runtime a launch uses (``ChromiumRuntimeStore/select(for:)``).
public enum ChromiumRuntimeSelection: Sendable, Equatable {
    /// The pack the app is pinned to is installed.
    case exact(ChromiumRuntimeInstallation)
    /// Another installed pack with the same shim ABI, folder and team: usable
    /// now, while the pinned one downloads (it takes over at the next launch).
    case compatible(ChromiumRuntimeInstallation)
    /// No usable pack is installed.
    case none

    /// The installation to run, nil for ``none``.
    public var installation: ChromiumRuntimeInstallation? {
        switch self {
        case .exact(let installation), .compatible(let installation): installation
        case .none: nil
        }
    }

    /// True when the pinned pack still has to be downloaded.
    public var needsDownload: Bool {
        if case .exact = self { return false }
        return true
    }
}
