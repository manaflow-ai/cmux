import CmuxLink
import CmuxLinkDirect
import Foundation

/// Runs the split-safe workloads on iOS (or another client process) against a
/// descriptor printed by ``BenchSplitServer``. The resulting `BenchReport`
/// uses the regular `cmux-link-bench/1` schema, so the existing bakeoff
/// summarizer can consume device output without a second table format.
public struct BenchSplitClient: Sendable {
    public let descriptor: BenchServeDescriptor
    public let deviceIdentity: DirectIdentity
    private let carrierFactory: @Sendable () throws -> [any LinkCarrier]
    private let splitRig: BenchRigKind

    public init(descriptor: BenchServeDescriptor, deviceIdentity: DirectIdentity) throws {
        try descriptor.validate()
        guard descriptor.carriers.contains(CarrierKind.direct.rawValue) else {
            throw BenchSplitError.invalidDescriptor("direct carrier missing")
        }
        self.descriptor = descriptor
        self.deviceIdentity = deviceIdentity
        self.splitRig = .v3
        carrierFactory = { [deviceIdentity] in
            [DirectCarrier(identity: deviceIdentity, resolver: DirectHintsResolver())]
        }
    }

    public init(descriptorData: Data, deviceIdentity: DirectIdentity) throws {
        try self.init(descriptor: BenchServeDescriptor.decode(descriptorData), deviceIdentity: deviceIdentity)
    }

    /// Creates a split client for a real B1 control-plane signaling channel or
    /// its in-memory test double. `rig` selects V1 or V2 when the descriptor
    /// advertises both; a descriptor with one signaling carrier may omit it.
    public init(
        descriptor: BenchServeDescriptor,
        signaling: BenchSignalingAdapters,
        rig: BenchRigKind,
        deviceIdentity: DirectIdentity = DirectIdentity()
    ) throws {
        try descriptor.validate()
        guard rig == .v1 || rig == .v2WebRTC else {
            throw BenchSplitError.invalidDescriptor("split signaling rig")
        }
        _ = try signaling.carriers(for: descriptor, selecting: rig)
        self.descriptor = descriptor
        self.deviceIdentity = deviceIdentity
        self.splitRig = rig
        carrierFactory = { [descriptor, signaling, rig] in
            try signaling.carriers(for: descriptor, selecting: rig)
        }
    }

    /// Runs the workloads listed in `spec`. Split mode intentionally rejects
    /// local-only fault/raw workloads instead of silently emitting an
    /// incomparable partial result.
    public func run(
        spec: BenchSpec,
        provenance: BenchReportProvenance? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> BenchReport {
        let requested = spec.workloads ?? Set(BenchWorkload.splitSupported)
        for workload in requested where !descriptor.workloads.contains(workload) {
            throw BenchSplitError.unsupportedWorkload(workload)
        }
        guard spec.bulkRecordBytes == descriptor.bulkRecordBytes else {
            throw BenchSplitError.server(
                "bulk record mismatch (client \(spec.bulkRecordBytes), server \(descriptor.bulkRecordBytes))"
            )
        }
        var splitSpec = spec
        splitSpec.rig = splitRig
        splitSpec.workloads = requested
        let descriptor = descriptor
        let carrierFactory = carrierFactory
        let runner = BenchRunner(spec: splitSpec) {
            try await BenchSplitFixture.connect(descriptor: descriptor, carriers: carrierFactory())
        }
        var report = await runner.run(progress: progress)
        report.provenance = provenance
        return report
    }
}
