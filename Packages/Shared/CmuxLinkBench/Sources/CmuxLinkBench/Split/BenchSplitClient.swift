import CmuxLinkDirect
import Foundation

/// Runs the split-safe workloads on iOS (or another client process) against a
/// descriptor printed by ``BenchSplitServer``. The resulting `BenchReport`
/// uses the regular `cmux-link-bench/1` schema, so the existing bakeoff
/// summarizer can consume device output without a second table format.
public struct BenchSplitClient: Sendable {
    public let descriptor: BenchServeDescriptor
    public let deviceIdentity: DirectIdentity

    public init(descriptor: BenchServeDescriptor, deviceIdentity: DirectIdentity) throws {
        try descriptor.validate()
        self.descriptor = descriptor
        self.deviceIdentity = deviceIdentity
    }

    public init(descriptorData: Data, deviceIdentity: DirectIdentity) throws {
        try self.init(descriptor: BenchServeDescriptor.decode(descriptorData), deviceIdentity: deviceIdentity)
    }

    /// Runs the workloads listed in `spec`. Split mode intentionally rejects
    /// local-only fault/raw workloads instead of silently emitting an
    /// incomparable partial result.
    public func run(
        spec: BenchSpec,
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
        splitSpec.rig = .v3
        splitSpec.workloads = requested
        let descriptor = descriptor
        let identity = deviceIdentity
        let runner = BenchRunner(spec: splitSpec) {
            try await BenchSplitFixture.connect(descriptor: descriptor, deviceIdentity: identity)
        }
        return await runner.run(progress: progress)
    }
}
