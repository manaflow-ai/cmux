/// One new blocking call site, as the detector hands it to a ``BlockingViolationSink``: a call on the main
/// thread, on a shared pool thread (``BlockingContext/pool``), in a `.cpu` lane item (``BlockingContext/cpuLane``)
/// or on a sync primitive in a lane item (``BlockingContext/laneSync``).
///
/// It carries no path, file name, symbol, argument or user text: the kind, the context and the stack as image
/// UUID + offset frames only (``BlockingFrame``).
public struct BlockingViolation: Sendable, Equatable {
    /// What the call waited on, or ``BlockingKind/wrongLane`` in ``BlockingContext/cpuLane``.
    public var kind: BlockingKind
    /// What the seam itself waited on: ``kind``, except at a ``BlockingKind/wrongLane`` violation.
    public var seamKind: BlockingKind
    /// Where it ran: ``BlockingContext/main``, ``BlockingContext/pool`` or ``BlockingContext/cpuLane`` (the other
    /// contexts may block).
    public var context: BlockingContext
    /// The stack, innermost first, starting at the blocking seam (at most 8 frames; an address in
    /// an image without a UUID is left out).
    public var frames: [BlockingFrame]

    /// Makes the value from its parts.
    public init(kind: BlockingKind, context: BlockingContext = .main, frames: [BlockingFrame],
                seamKind: BlockingKind? = nil) {
        self.kind = kind
        self.seamKind = seamKind ?? kind
        self.context = context
        self.frames = frames
    }
}
