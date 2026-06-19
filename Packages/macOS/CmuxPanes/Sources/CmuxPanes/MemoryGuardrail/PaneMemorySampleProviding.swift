public import Foundation

/// Off-main producer of per-pane memory samples for the guardrail.
///
/// The guardrail service runs these on a detached utility/user-initiated task,
/// so the conformer must be `Sendable` and its methods `nonisolated`. The
/// concrete app-side conformer attributes a pane's process-tree memory by
/// controlling tty against the live `top`-style process snapshot; that snapshot
/// subsystem stays in the app target and is reached only through this seam, so
/// the panes package never imports libproc.
public protocol PaneMemorySampleProviding: Sendable {
    /// Samples computed from a short-lived cached process snapshot (the per-tick
    /// scan path; the cache amortizes repeated captures across subsystems).
    func cachedSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64
    ) -> [PaneMemorySample]

    /// Samples computed from a freshly captured process snapshot (the kill /
    /// SIGKILL-revalidation path, which must not trust a stale cache).
    func freshSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64
    ) -> [PaneMemorySample]
}
