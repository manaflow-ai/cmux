import CmuxNextDaemon

/// Per-machine capability negotiation. `identify` reports each daemon's
/// protocol, build and capabilities; the app turns a feature on only where
/// the machine's daemon reports it, and says "update this machine" where a
/// Cloud machine's own cmux-tui is too old (plans/cmux-next/cloud-ios.md,
/// "Remote daemon compatibility").
extension DaemonService {
    /// What this machine's daemon can do for the app: from the handshake
    /// that refused it while `startup` shows that refusal, else from the
    /// current identity. Nil before the first answer.
    /// Home-only capabilities never count against a remote machine; use
    /// `MachineRegistry.compatibility(of:)` to also drop the ones personal
    /// state moved to the local daemon.
    var compatibility: DaemonCompatibility? {
        compatibility(notNeeded: isLocal ? [] : Set(DaemonCapabilities.homeOnly))
    }

    func compatibility(notNeeded: Set<String>) -> DaemonCompatibility? {
        if case .unavailable(let error) = startup, let refused = DaemonCompatibility(refusal: error) { return refused }
        return identity.map { DaemonCompatibility(identity: $0, notNeeded: notNeeded) }
    }

    /// The refusal for an action that needs `capability`: on a Cloud machine
    /// it tells the user to update that machine, locally it names the
    /// capability the bundled cmux-tui lacks.
    func missingCapabilityMessage(_ capability: String) -> String {
        isLocal ? RefusalStrings.needsDaemonCapability(capability) : RefusalStrings.updateCloudMachine(capability)
    }
}
