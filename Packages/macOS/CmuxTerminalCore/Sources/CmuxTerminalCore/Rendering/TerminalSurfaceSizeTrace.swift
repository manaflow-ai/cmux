public import CoreGraphics

/// A `#if DEBUG` surface-size decision trace emitted by
/// ``TerminalSurfaceRenderCoordinator`` through the host seam.
///
/// The legacy `updateSurfaceSize()` body emitted `cmuxDebugLog` lines for each
/// defer/resume reason, deduped by a per-view `lastSizeSkipSignature` string.
/// The coordinator owns the signature dedup and hands the host a structured
/// trace to format and emit, so the package never references the app debug-log
/// sink directly.
public enum TerminalSurfaceSizeTrace: Sendable {
    /// The size update was deferred for a reason (e.g. `nonPositive`, `tabDrag`,
    /// `noWindow`, `zeroBacking`).
    case deferred(reason: String, size: CGSize, backingSize: CGSize?, inWindow: Bool)

    /// A previously deferred size update resumed.
    case resumed(size: CGSize, backingSize: CGSize)
}
