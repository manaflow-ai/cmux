#if DEBUG || CMUX_BENCH_HOOKS
/// Builds one facet from model values, only when a snapshot asks for it: a provider keeps no
/// observer and no cache. Providers are values the composition root (AppServices, the headless
/// services) puts in one ``OracleFacets`` list; there is no shared registry.
public protocol OracleFacetProvider: Sendable {
    var facet: OracleFacet { get }
    var capture: OracleFacetCapture { get }
}

/// Where a provider reads its model.
public enum OracleFacetCapture: Sendable {
    /// Main-actor model values (windows, focus, layout, sidebar). All main-actor facets of one
    /// snapshot run in the same main-actor turn, so they describe one state of the model. The body
    /// reads values only: no disk, no database, no wait (p15-oracle.md section 4, rule 7).
    case mainActor(@MainActor @Sendable () throws(OracleFacetError) -> OracleValue)
    /// State owned off the main actor (daemon vt-state, a store actor). Runs after the main-actor
    /// turn, concurrently with the other background facets of the snapshot.
    case background(@Sendable () async throws(OracleFacetError) -> OracleValue)
}

/// A provider given as its facet and capture, for a facet whose read fits in one closure.
public struct OracleFacetSource: OracleFacetProvider {
    public let facet: OracleFacet
    public let capture: OracleFacetCapture

    public init(_ facet: OracleFacet, _ capture: OracleFacetCapture) {
        self.facet = facet
        self.capture = capture
    }
}
#endif
