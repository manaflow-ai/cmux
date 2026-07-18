/// Gates optional render instrumentation behind explicit demand.
///
/// Frame-rendered and tick notifications exist only for observers (the mobile
/// render observer, debug HUDs). Posting them unconditionally would add work
/// to the render hot path, so producers first check ``isActive`` and skip the
/// notification entirely while nobody has retained demand.
///
/// Isolation: requirements are synchronous and `Sendable` on purpose. A hot
/// renderer callback can neither await an actor nor hop to the main actor,
/// while retainers may call from the main actor. Implementations therefore
/// guard a tiny counter with a synchronous compare-and-set primitive rather
/// than introducing an asynchronous hop into frame admission.
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
