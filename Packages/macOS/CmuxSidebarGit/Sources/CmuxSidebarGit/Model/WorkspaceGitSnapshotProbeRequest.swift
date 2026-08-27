/// One panel's membership in a per-directory metadata snapshot probe.
///
/// Multiple panels sharing a directory join one snapshot task; each remembers
/// whether the joining attempt was the panel's last retry so the apply path
/// can finish or keep the probe alive per panel.
struct WorkspaceGitSnapshotProbeRequest: Sendable {
    let probeKey: WorkspaceGitProbeKey
    let isLastAttempt: Bool
}
