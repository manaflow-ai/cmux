/// One new main-thread blocking call site, as the detector hands it to a ``BlockingViolationSink``.
///
/// It carries no path, file name, symbol, argument or user text: the kind and the stack as image
/// UUID + offset frames only (``BlockingFrame``).
public struct BlockingViolation: Sendable, Equatable {
    /// What the call waited on.
    public var kind: BlockingKind
    /// The stack, innermost first, starting at the blocking seam (at most 8 frames; an address in
    /// an image without a UUID is left out).
    public var frames: [BlockingFrame]

    /// Makes the value from its parts.
    public init(kind: BlockingKind, frames: [BlockingFrame]) {
        self.kind = kind
        self.frames = frames
    }
}
