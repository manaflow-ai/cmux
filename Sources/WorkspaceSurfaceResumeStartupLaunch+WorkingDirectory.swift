import CmuxWorkspaces

extension WorkspaceSurfaceResumeStartupLaunch {
    /// Moves the user's already-initialized shell before delivering resume input.
    ///
    /// Keeping the directory change in the parent shell means the agent can exit
    /// naturally without cmux replacing that shell or replaying its startup files.
    func restoringWorkingDirectory(_ workingDirectory: String?) -> Self {
        return .input(TerminalStartupWorkingDirectoryPrefix.prefix(
            initialInput,
            workingDirectory: workingDirectory
        ))
    }
}
