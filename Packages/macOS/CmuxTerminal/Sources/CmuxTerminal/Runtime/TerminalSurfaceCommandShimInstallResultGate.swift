/// Accepts either an install result or its deadline, exactly once.
actor TerminalSurfaceCommandShimInstallResultGate {
    private var isClaimed = false

    func acceptResult() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }

    func expire() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
