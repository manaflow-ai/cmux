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
        compatibility(notNeeded: isLocal ? [] : Set(DaemonCapabilities.shared.homeOnly))
    }

    func compatibility(notNeeded: Set<String>) -> DaemonCompatibility? {
        if case .unavailable(let error) = startup, let refused = DaemonCompatibility(refusal: error) { return refused }
        return identity.map { DaemonCompatibility(identity: $0, notNeeded: notNeeded) }
    }

    /// The one capability gate's reason for an action that needs
    /// `capability` on this machine (`ActionRegistry.bind(requires:)`, the
    /// sidebar and every handler use it). Never the capability id: before
    /// the daemon answers, it says the service is starting; on a Cloud
    /// machine, update that machine; locally, restart cmux when this tree's
    /// daemon serves the capability (the running one is older), else the
    /// feature is not in this build.
    func missingCapabilityMessage(_ capability: String) -> String {
        if isLocal, startup.isUnavailable { return RefusalStrings.daemonUnavailable }
        if identity == nil { return isLocal ? RefusalStrings.daemonConnecting : CloudStrings.notConnected }
        return isLocal ? RefusalStrings.needsDaemonCapability(capability) : RefusalStrings.updateCloudMachine
    }

    /// The home daemon may still bring personal state: it has not answered
    /// yet, or it serves `profiles-v1` (its next snapshot carries it).
    var personalStateMayLoad: Bool {
        !startup.isUnavailable && (identity == nil || supports(DaemonCapabilities.shared.profiles))
    }

    /// Why the home session's personal state (spaces, workspace groups) is
    /// not usable now: still loading on a daemon that serves `profiles-v1`,
    /// else the capability gate's reason.
    var personalStateUnavailableReason: String {
        let capability = DaemonCapabilities.shared.profiles
        return supports(capability) && !startup.isUnavailable ? RefusalStrings.personalStateLoading : missingCapabilityMessage(capability)
    }
}
