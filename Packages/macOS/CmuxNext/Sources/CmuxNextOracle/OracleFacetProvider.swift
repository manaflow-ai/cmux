#if DEBUG || CMUX_BENCH_HOOKS
/// Builds one facet from model values, only when a snapshot asks for it: a provider keeps no
/// observer and no cache. Providers are values the composition root (AppServices) puts in one
/// ``OracleFacets`` list; there is no shared registry.
public protocol OracleFacetProvider: Sendable {
    var facet: OracleFacet { get }
    var read: OracleFacetRead { get }
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

/// A facet's read of main-actor model values (windows, focus, overlays). All facets of one snapshot run in the
/// same main-actor turn, so they describe one state of the model. The body reads values only: no disk, no
/// database, no wait.
public typealias OracleFacetRead = @MainActor @Sendable () throws(OracleFacetError) -> OracleValue

/// A provider given as its facet and read, for a facet whose read fits in one closure.
public struct OracleFacetSource: OracleFacetProvider {
    public let facet: OracleFacet
    public let read: OracleFacetRead
    public let changes: OracleFacetChanges?

    public init(_ facet: OracleFacet, changes: OracleFacetChanges? = nil, read: @escaping OracleFacetRead) {
        self.facet = facet
        self.read = read
        self.changes = changes
    }
}
#endif
