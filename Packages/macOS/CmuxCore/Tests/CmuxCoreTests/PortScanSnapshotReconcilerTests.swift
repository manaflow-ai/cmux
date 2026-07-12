import Testing
@testable import CmuxCore

@Suite("Port scan snapshot reconciliation")
struct PortScanSnapshotReconcilerTests {
    @Test("One complete miss cannot remove a known port")
    func transientCompleteMissRetainsPort() {
        var reconciler = PortScanSnapshotReconciler<String>(missingPortRetentionLimit: 1)

        reconciler.reconcile(
            scannedPorts: ["workspace": [4200]],
            scannedKeys: ["workspace"],
            trackedKeys: ["workspace"],
            completeness: .complete
        )
        let snapshot = reconciler.reconcile(
            scannedPorts: ["workspace": []],
            scannedKeys: ["workspace"],
            trackedKeys: ["workspace"],
            completeness: .complete
        )

        #expect(snapshot == ["workspace": [4200]])
    }

    @Test("Sustained complete misses eventually remove a port")
    func sustainedCompleteMissRemovesPort() {
        var reconciler = PortScanSnapshotReconciler<String>(missingPortRetentionLimit: 1)
        reconciler.reconcile(
            scannedPorts: ["workspace": [4200]],
            scannedKeys: ["workspace"],
            trackedKeys: ["workspace"],
            completeness: .complete
        )
        reconciler.reconcile(
            scannedPorts: [:],
            scannedKeys: ["workspace"],
            trackedKeys: ["workspace"],
            completeness: .complete
        )

        let snapshot = reconciler.reconcile(
            scannedPorts: [:],
            scannedKeys: ["workspace"],
            trackedKeys: ["workspace"],
            completeness: .complete
        )

        #expect(snapshot.isEmpty)
    }

    @Test("Incomplete scans merge positive evidence without removing missing ports")
    func incompleteScanOnlyAddsEvidence() {
        var reconciler = PortScanSnapshotReconciler<String>()
        reconciler.reconcile(
            scannedPorts: ["workspace": [3000, 4200]],
            scannedKeys: ["workspace"],
            trackedKeys: ["workspace"],
            completeness: .complete
        )

        let snapshot = reconciler.reconcile(
            scannedPorts: ["workspace": [5173]],
            scannedKeys: ["workspace"],
            trackedKeys: ["workspace"],
            completeness: .incomplete
        )

        #expect(snapshot == ["workspace": [3000, 4200, 5173]])
    }

    @Test("Stopping tracking removes ports immediately")
    func untrackedKeyIsRemovedImmediately() {
        var reconciler = PortScanSnapshotReconciler<String>()
        reconciler.reconcile(
            scannedPorts: ["workspace": [4200]],
            scannedKeys: ["workspace"],
            trackedKeys: ["workspace"],
            completeness: .complete
        )

        let snapshot = reconciler.reconcile(
            scannedPorts: [:],
            scannedKeys: [],
            trackedKeys: [],
            completeness: .incomplete
        )

        #expect(snapshot.isEmpty)
    }
}
