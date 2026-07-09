/// Where a panel directory report came from, controlling whether the
/// restored-guarded-directory guard applies and whether a remote directory
/// establishes trusted remote provenance.
public enum PanelDirectoryUpdateSource: Sendable {
    /// A live cwd report from OSC 7 / shell integration.
    case liveReport
    /// A live cwd report from the remote shell/PTY control path.
    case remoteReport
    /// A directory replayed from restored session-snapshot metadata.
    case restoredSnapshotMetadata
    /// A trusted remote directory replayed from restored session-snapshot metadata.
    case trustedRestoredRemoteSnapshotMetadata

    /// Whether the source is a live shell report and should run through the
    /// restored-guarded-directory filter.
    public var isLiveReport: Bool {
        switch self {
        case .liveReport, .remoteReport:
            return true
        case .restoredSnapshotMetadata, .trustedRestoredRemoteSnapshotMetadata:
            return false
        }
    }

    /// Whether this source can establish remote-directory provenance when the
    /// app-side workspace deems the report remote-trusted.
    public var establishesRemoteProvenance: Bool {
        switch self {
        case .remoteReport, .trustedRestoredRemoteSnapshotMetadata:
            return true
        case .liveReport, .restoredSnapshotMetadata:
            return false
        }
    }
}
