public import CmuxNextCloud

extension MachineServerState {
    /// What a Cloud machine's row says from its server record and the app's stage for it (the Cloud
    /// page's own reading, `CloudMachineStage`): a paused machine nothing attaches to reads "Paused",
    /// and one an attach or a click is resuming reads "Resuming…" with a spinner (a resume that failed
    /// reads "Failed"); a failed machine reads "Failed", a destroyed one "Deleted". Nil while it runs
    /// or starts, so the row follows its link: a spinner only for a genuine connect. A paused machine's
    /// daemon store may sit in `.connecting`, which is not a connect anyone can wait on. Other statuses
    /// (unknown, or transitions a newer server reports) follow the link too.
    /// - Parameters:
    ///   - stagePaused: the stage is paused (nothing attached yet).
    ///   - stageFailed: the stage is failed; read only when the stage is not paused.
    public nonisolated static func cloud(_ status: CloudMachine.Status, stagePaused: Bool, stageFailed: Bool) -> MachineServerState? {
        switch status {
        case .paused: stagePaused ? .paused : stageFailed ? .failed : .resuming
        case .failed: .failed
        case .destroyed: .deleted
        default: nil
        }
    }
}
