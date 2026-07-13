/// Progress events streamed while a provisioning operation runs; the CLI
/// renders these as step lines (and localizes the presentation).
public enum VPSProvisioningEvent: Equatable, Sendable {
    /// Probing the host over SSH.
    case probing(destination: String)
    /// Probe finished; platform and distro identified.
    case probed(goOS: String, goArch: String, distro: String)
    /// Plan computed.
    case planned(VPSProvisioningPlan)
    /// Acquiring the verified daemon binary locally.
    case acquiringArtifact(version: String)
    /// One plan step is being applied.
    case applying(VPSProvisioningStep)
    /// Advisory note surfaced mid-run.
    case note(VPSProvisioningPlan.Note)
    /// End-to-end health check finished.
    case healthChecked(VPSHostHealth)
    /// Provisioning finished; terminal event of `add`/`upgrade` streams.
    case completed(VPSProvisionOutcome)
    /// Teardown finished; terminal event of `remove` streams.
    case removed(VPSRemovalOutcome)
}
