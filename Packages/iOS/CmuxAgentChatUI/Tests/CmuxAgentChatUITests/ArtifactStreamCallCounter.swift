/// Records whether an artifact stream was invoked without shared test globals.
actor ArtifactStreamCallCounter {
    private var count = 0

    func recordCall() {
        count += 1
    }

    func callCount() -> Int {
        count
    }
}
