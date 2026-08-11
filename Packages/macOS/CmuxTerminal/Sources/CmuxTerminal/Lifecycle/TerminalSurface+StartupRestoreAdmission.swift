extension TerminalSurface {
    /// Releases a startup-restore terminal after its owner commits responder state.
    ///
    /// The transition is idempotent. The first admission synchronously requests
    /// native runtime startup through the normal headless bootstrap path, which
    /// preserves any restore pacing carried by the surface's spawn policy.
    /// Calls for unrestricted or already-admitted surfaces are no-ops.
    @MainActor
    public func admitStartupRestoreRuntime() {
        guard startupRestoreAdmissionPhase == .awaitingAdmission else { return }
        startupRestoreAdmissionPhase = .admitted
        scheduleHeadlessRuntimeStartIfNeeded(reason: "startup-restore-admitted")
    }
}
