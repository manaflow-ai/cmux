#if DEBUG || CMUX_BENCH_HOOKS
/// Builds one facet from model values, only when a snapshot asks for it: a provider keeps no
/// observer and no cache. Providers are values the composition root (AppServices, the headless
/// services) puts in one ``OracleFacets`` list; there is no shared registry.
public protocol OracleFacetProvider: Sendable {
    var facet: OracleFacet { get }
    var capture: OracleFacetCapture { get }
    /// The facet's change signal, nil when the owners give none.
    var changes: OracleFacetChanges? { get }
}

extension OracleFacetProvider {
    public var changes: OracleFacetChanges? { nil }
}

/// Subscribes to a facet's changes: the stream yields once for each change of the state the facet reads, from
/// the owning actor's own state-change point (no poll), and finishes when the subscriber cancels or the owner
/// goes away. Each call is a new subscription.
public typealias OracleFacetChanges = @Sendable () -> AsyncStream<Void>

/// Where a provider reads its model.
public enum OracleFacetCapture: Sendable {
    /// Main-actor model values (windows, focus, layout, sidebar). All main-actor facets of one
    /// snapshot run in the same main-actor turn, so they describe one state of the model. The body
    /// reads values only: no disk, no database, no wait (p15-oracle.md section 4, rule 7).
    case mainActor(@MainActor @Sendable () throws(OracleFacetError) -> OracleValue)
    /// State owned off the main actor (daemon vt-state, a store actor). Runs after the main-actor
    /// turn, concurrently with the other background facets of the snapshot.
    case background(OracleFacetRead)
    /// Main-actor model values plus state owned off the main actor: the main-actor part runs in the snapshot's
    /// main-actor turn with the `mainActor` facets (so the snapshot describes one state of the model), reads
    /// values only (the same rule), and returns the slow part, which runs off the main actor as a background
    /// facet does. The `terminals` facet lists the mirror's terminals in the turn and reads their screens later.
    case split(@MainActor @Sendable () throws(OracleFacetError) -> OracleFacetRead)
}

/// A facet read that runs off the main actor.
public typealias OracleFacetRead = @Sendable () async throws(OracleFacetError) -> OracleValue

/// A provider given as its facet and capture, for a facet whose read fits in one closure.
public struct OracleFacetSource: OracleFacetProvider {
    public let facet: OracleFacet
    public let capture: OracleFacetCapture
    public let changes: OracleFacetChanges?

    public init(_ facet: OracleFacet, _ capture: OracleFacetCapture, changes: OracleFacetChanges? = nil) {
        self.facet = facet
        self.capture = capture
        self.changes = changes
    }
}
#endif
