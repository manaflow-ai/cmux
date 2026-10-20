/// Internal capability for reading a redaction-boundary path snapshot.
protocol CmxIrohConnectionPathInspecting: Sendable {
    func observedSelectedPath() async -> CmxIrohObservedConnectionPath
    func observedSelectedPathChanges() async -> AsyncStream<CmxIrohObservedConnectionPath>
}
