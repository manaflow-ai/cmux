extension TerminalSurface {
    /// Releases a startup-restore terminal after its owner commits responder state.
    ///
    /// The transition is idempotent. The first admission synchronously requests
    /// native runtime startup through the normal headless bootstrap path. Calls
    /// for immediate, paced, or already-admitted surfaces are no-ops.
    @MainActor
    public func admitStartupRestoreRuntime() {
        guard startupRestoreAdmissionPhase == .awaitingAdmission else { return }
        startupRestoreAdmissionPhase = .admitted
        scheduleHeadlessRuntimeStartIfNeeded(reason: "startup-restore-admitted")
    }
}
