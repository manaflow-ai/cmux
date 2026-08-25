extension TerminalSurface {
    /// Releases a startup-restore terminal after its owner commits responder state.
    ///
    /// The transition is idempotent. The first admission synchronously requests
    /// native runtime startup through the normal headless bootstrap path, which
    /// preserves any restore pacing carried by the surface's spawn policy.
    /// Calls for unrestricted or already-admitted surfaces are no-ops.
    @MainActor
    @discardableResult
    public func admitStartupRestoreRuntime(initialInput: String? = nil) -> Bool {
        guard startupRestoreAdmissionPhase == .awaitingAdmission else { return false }
        if let initialInput {
            prepareNextRuntimeInitialInput(initialInput)
        }
        suppressConfiguredInitialInput = false
        startupRestoreAdmissionPhase = .admitted
        scheduleHeadlessRuntimeStartIfNeeded(reason: "startup-restore-admitted")
        return true
    }

    /// Releases a deferred restore without admitting its staged command.
    ///
    /// This is used when ownership is ambiguous or the user explicitly
    /// interacts with the shell. The first runtime then starts as a plain shell.
    @MainActor
    public func cancelStartupRestoreAdmission() {
        guard startupRestoreAdmissionPhase == .awaitingAdmission else { return }
        nextRuntimeInitialInput = nil
        suppressConfiguredInitialInput = true
        startupRestoreAdmissionPhase = .admitted
        scheduleHeadlessRuntimeStartIfNeeded(reason: "startup-restore-cancelled")
    }

    @MainActor
    func cancelStartupRestoreAdmissionForExplicitInput() {
        guard startupRestoreAdmissionPhase == .awaitingAdmission else { return }
        nextRuntimeInitialInput = nil
        suppressConfiguredInitialInput = true
        startupRestoreAdmissionPhase = .admitted
        // User input is an immediate runtime demand; do not make the first
        // keystroke wait behind the unrelated paced-restore queue.
        scheduleHeadlessRuntimeStartIfNeeded(
            reason: "startup-restore-cancelled-by-input",
            source: .inputDemand
        )
        onStartupRestoreAdmissionCancelled?()
    }
}
