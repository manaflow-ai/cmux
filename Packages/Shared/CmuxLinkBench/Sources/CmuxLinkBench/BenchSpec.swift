/// What to run: one rig, its path impairment, the workloads and their size.
public struct BenchSpec: Sendable {
    public var rig: BenchRigKind
    public var rttMilliseconds: Double
    public var loss: Double
    public var quick: Bool
    /// Message size of the bulk-file workload.
    public var bulkRecordBytes: Int = 64 * 1024
    /// nil runs every workload.
    public var workloads: Set<BenchWorkload>?

    public init(rig: BenchRigKind, rttMilliseconds: Double = 0, loss: Double = 0, quick: Bool = false, workloads: Set<BenchWorkload>? = nil) {
        self.rig = rig
        self.rttMilliseconds = rttMilliseconds
        self.loss = loss
        self.quick = quick
        self.workloads = workloads
    }

    func runs(_ workload: BenchWorkload) -> Bool { workloads?.contains(workload) ?? true }

    var connectSamples: Int { quick ? 3 : 5 }
    var recoverySamples: Int { quick ? 2 : 3 }
    var rttBudget: Duration { quick ? .seconds(3) : .seconds(6) }
    var rttMaxSamples: Int { quick ? 300 : 1000 }
    var transferWindow: Duration { quick ? .seconds(2) : .seconds(4) }
}
