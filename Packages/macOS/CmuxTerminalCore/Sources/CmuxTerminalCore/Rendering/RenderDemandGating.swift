/// Gates optional render instrumentation behind explicit demand.
///
/// Frame-rendered and tick notifications exist only for observers (the mobile
/// render observer, debug HUDs). Posting them unconditionally would add work
/// to the render hot path, so producers first check ``isActive`` and skip the
/// notification entirely while nobody has retained demand.
///
/// Isolation: requirements are synchronous and `Sendable` on purpose. The hot
/// reader is `GhosttyMetalLayer.nextDrawable()` on the renderer thread, which
/// can neither await an actor nor hop to the main actor; retainers call from
/// the main actor. Implementations therefore guard a tiny counter with a lock
/// (the sanctioned shape for state shared with synchronous off-main readers)
/// rather than actor isolation.
public protocol RenderDemandGating: AnyObject, Sendable {
    /// Registers one unit of demand.
    ///
    /// Demand stays active until the returned retention is released. Callers
    /// hold the retention for as long as they need notifications.
    func retain() -> any RenderDemandRetention

    /// Whether at least one retention is currently outstanding.
    var isActive: Bool { get }
}

/// One outstanding unit of render demand returned by
/// ``RenderDemandGating/retain()``.
///
/// Releasing is idempotent: a retention decrements its gate exactly once no
/// matter how many times ``release()`` is called.
public protocol RenderDemandRetention: AnyObject, Sendable {
    /// Ends this unit of demand.
    func release()
}
