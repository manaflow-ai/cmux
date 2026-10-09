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

    /// Resolves the entry-point selection without opening a socket. A
    /// descriptor advertising one carrier is unambiguous; descriptors with
    /// multiple carriers require an explicit rig so a benchmark never falls
    /// back to a different transport by accident.
    public static func resolveRig(
        _ requested: BenchRigKind?, descriptor: BenchServeDescriptor
    ) throws -> BenchRigKind {
        try descriptor.validate()
        let advertised = Set(descriptor.carriers.map(CarrierKind.init(rawValue:)))
        let selected: BenchRigKind
        if let requested {
            selected = requested
        } else {
            guard advertised.count == 1, let only = advertised.first else {
                throw BenchSplitError.invalidDescriptor("multiple carriers require an explicit rig")
            }
            if only == .direct {
                selected = .v3
            } else if only == .webrtc {
                selected = .v1
            } else if only == .webrtcWireGuard {
                selected = .v2WebRTC
            } else {
                throw BenchSplitError.invalidDescriptor("unsupported split carrier \(only.rawValue)")
            }
        }
        let carrier: CarrierKind
        switch selected {
        case .v1: carrier = .webrtc
        case .v2WebRTC: carrier = .webrtcWireGuard
        case .v3: carrier = .direct
        case .v2Memory, .reference:
            throw BenchSplitError.invalidDescriptor("split entry point does not support rig \(selected.rawValue)")
        }
        guard advertised.contains(carrier) else {
            throw BenchSplitError.invalidDescriptor("rig \(selected.rawValue) is not advertised")
        }
        return selected
    }

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
    /// its in-memory test double. Call ``resolveRig(_:descriptor:)`` at an
    /// entry point first when the descriptor may advertise one or more
    /// carriers; this initializer then requires the explicit V1/V2 choice.
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
