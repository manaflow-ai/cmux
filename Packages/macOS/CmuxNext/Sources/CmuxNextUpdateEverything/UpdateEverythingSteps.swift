/// The update paths Update Everything drives, one per kind of change. The App conforms with its
/// existing paths (Sparkle, `RemoteInstaller` over SSH, `cmux link machine update` for Cloud, the
/// daemon's agent CLI updates) so ``UpdateEverythingRunner`` never names a concrete service.
@MainActor
public protocol UpdateEverythingSteps: AnyObject, Sendable {
    /// Replaces the machine's cmux daemon with this app's build and returns once the new daemon
    /// answers; its terminals and agents carry over. Called only for a machine whose
    /// ``UpdateEverythingMachine/daemon`` is set.
    /// - Throws: Why the machine could not be updated, in words for the person.
    func updateDaemon(on machine: UpdateEverythingMachine) async throws
    /// The machine's outdated agent CLIs as its daemon lists them now (after a daemon update).
    func outdatedAgents(on machine: UpdateEverythingMachine) async -> [UpdateEverythingChange]
    /// Runs the machine daemon's own update of each outdated agent CLI and waits for it; with
    /// `continueThreads`, then restarts the machine's live threads on the new CLIs, each resuming
    /// its own conversation (a thread in a turn restarts when that turn ends).
    /// - Returns: Why some of the machine's threads still run the old agent (they could not
    ///   restart), or nil.
    /// - Throws: Why an update failed, in words for the person.
    func updateAgents(on machine: UpdateEverythingMachine, continueThreads: Bool) async throws -> String?
    /// Installs the app's staged or found update and relaunches; the last step of a run.
    /// - Throws: Why the app cannot update now.
    func installApp() throws
}
