/// Internal capability for reading a redaction-boundary path snapshot.
protocol CmxIrohConnectionPathInspecting: Sendable {
    func observedSelectedPath() async -> CmxIrohObservedConnectionPath
    func observedSelectedPathChanges() async -> AsyncStream<CmxIrohObservedConnectionPath>
    /// A non-lossy path stream reserved for hard session-policy enforcement.
    func policySelectedPathChanges() async -> AsyncStream<CmxIrohObservedConnectionPath>
}
