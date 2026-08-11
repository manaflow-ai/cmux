actor TerminalSurfaceLaunchResourceProviderState {
    private var snapshot: TerminalSurfaceLaunchResourceSnapshot?

    func install(_ snapshot: TerminalSurfaceLaunchResourceSnapshot) {
        self.snapshot = snapshot
    }

    func current() -> TerminalSurfaceLaunchResourceSnapshot? {
        snapshot
    }
}
