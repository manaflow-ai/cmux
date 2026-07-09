/// Decides whether a portal's queued external-geometry sync should flush the
/// latest visible frame immediately instead of deferring it behind the next
/// runloop turn or rescheduling behind a drag stream.
///
/// During an interactive resize (live window or host-view resize, or a split /
/// sidebar drag) or an explicit forced request, new geometry requests arrive
/// faster than a queued sync runs, so the portal must flush the latest frame now
/// rather than resize the PTY at a stale intermediate width. This value type
/// holds the boolean inputs of that decision and computes the pure OR.
///
/// The live AppKit reads (`NSView.inLiveResize` on the host view and window, and
/// the interactive-resize tracker flag) stay in the portal and are passed in as
/// plain `Bool`s, so nothing here touches AppKit or window state. Each input is a
/// side-effect-free read, so evaluating them all up front yields the same result
/// as the original short-circuited OR.
public struct ExternalGeometrySyncFlushPolicy: Sendable {
    /// The caller explicitly requested an immediate flush.
    public let forceImmediate: Bool

    /// A coalesced earlier request asked for an immediate flush.
    public let pendingRequiresImmediate: Bool

    /// The host view is in an AppKit live resize.
    public let hostInLiveResize: Bool

    /// The window is in an AppKit live resize.
    public let windowInLiveResize: Bool

    /// An interactive geometry resize (split or sidebar drag) is active.
    public let interactiveResizeActive: Bool

    /// Creates a flush-decision input set.
    /// - Parameters:
    ///   - forceImmediate: Whether the caller explicitly requested an immediate flush.
    ///   - pendingRequiresImmediate: Whether a coalesced earlier request requires immediate flush.
    ///   - hostInLiveResize: Whether the host view is in an AppKit live resize.
    ///   - windowInLiveResize: Whether the window is in an AppKit live resize.
    ///   - interactiveResizeActive: Whether an interactive geometry resize is active.
    public init(
        forceImmediate: Bool,
        pendingRequiresImmediate: Bool,
        hostInLiveResize: Bool,
        windowInLiveResize: Bool,
        interactiveResizeActive: Bool
    ) {
        self.forceImmediate = forceImmediate
        self.pendingRequiresImmediate = pendingRequiresImmediate
        self.hostInLiveResize = hostInLiveResize
        self.windowInLiveResize = windowInLiveResize
        self.interactiveResizeActive = interactiveResizeActive
    }

    /// Whether the queued sync should flush the latest visible frame now.
    public var shouldFlushLatest: Bool {
        forceImmediate
            || pendingRequiresImmediate
            || hostInLiveResize
            || windowInLiveResize
            || interactiveResizeActive
    }
}
