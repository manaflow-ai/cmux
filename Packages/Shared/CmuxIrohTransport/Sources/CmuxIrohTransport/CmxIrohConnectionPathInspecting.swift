/// Internal capability for reading raw snapshots and redacted selected-path state.
protocol CmxIrohConnectionPathInspecting: Sendable {
    func connectionPathSnapshots() async -> [CmxIrohConnectionPathSnapshot]
    func observedSelectedPath() async -> CmxIrohObservedConnectionPath
    func observedSelectedPathChanges() async -> AsyncStream<CmxIrohObservedConnectionPath>
}
