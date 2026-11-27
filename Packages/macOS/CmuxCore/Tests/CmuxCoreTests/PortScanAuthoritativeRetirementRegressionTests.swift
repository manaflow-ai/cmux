import Testing
@testable import CmuxCore

@Suite("Bounded port snapshot retirement")
struct PortScanAuthoritativeRetirementRegressionTests {
    private enum Scope: Hashable, Sendable {
        case panel
        case workspace
    }

    /// Verifies bounded listener retirement for every shared publication scope.
    @Test("Complete scans retire a stopped listener within one burst in every scope")
    func completeScansRetireStoppedListenerWithinBurst() {
        let port = 48_123
        let scopes: Set<Scope> = [.panel, .workspace]
        var reconciler = PortScanSnapshotReconciler<Scope>()

        let published = reconciler.reconcile(
            scannedPorts: [.panel: [port], .workspace: [port]],
            scannedKeys: scopes,
            trackedKeys: scopes,
            completeness: .complete
        )
        #expect(published == [.panel: [port], .workspace: [port]])

        for miss in 1...3 {
            let snapshot = reconciler.reconcile(
                scannedPorts: [.panel: [], .workspace: []],
                scannedKeys: scopes,
                trackedKeys: scopes,
                completeness: .complete
            )

            if miss < 3 {
                #expect(snapshot == [.panel: [port], .workspace: [port]])
            } else {
                #expect(snapshot.isEmpty)
            }
        }
    }
}
