extension TerminalSurfaceRuntimeTeardownCoordinator {
    /// Executes a native selection read in the teardown-serialized lane.
    func readSelection(
        _ request: TerminalSurfaceRuntimeSelectionRequest
    ) -> TerminalSurfaceSelectionRead {
        request.read()
    }
}
