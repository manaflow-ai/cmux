/// One new blocking call site, as the detector hands it to a ``BlockingViolationSink``: a call on the main
/// thread, or on a shared pool thread (``BlockingContext/pool``).
///
/// It carries no path, file name, symbol, argument or user text: the kind, the context and the stack as image
/// UUID + offset frames only (``BlockingFrame``).
public struct BlockingViolation: Sendable, Equatable {
    /// What the call waited on.
    public var kind: BlockingKind
    /// Where it ran: ``BlockingContext/main`` or ``BlockingContext/pool`` (the other contexts may block).
    public var context: BlockingContext
    /// The stack, innermost first, starting at the blocking seam (at most 8 frames; an address in
    /// an image without a UUID is left out).
    public var frames: [BlockingFrame]

    /// Makes the value from its parts.
    public init(kind: BlockingKind, context: BlockingContext = .main, frames: [BlockingFrame]) {
        self.kind = kind
        self.context = context
        self.frames = frames
    }
}
