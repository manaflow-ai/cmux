#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's facet providers: one immutable list the composition root builds once
/// (p15-oracle.md section 4, rule 4: no singleton, no static registry). `debug.oracle.snapshot`
/// asks it for the facets a case names; a facet with no provider in this build answers
/// not-comparable, never absent, so the diff can never pass it.
///
/// A snapshot is one main-actor turn: ``snapshot(_:)`` runs every requested provider in it.
public struct OracleFacets: Sendable {
    private let providers: [OracleFacet: any OracleFacetProvider]
    /// Facets that more than one provider named; the first provider in the list answers. The App
    /// test of its own list expects none.
    public let duplicates: [OracleFacet]

    public init(_ list: [any OracleFacetProvider]) {
        var providers: [OracleFacet: any OracleFacetProvider] = [:]
        var duplicates: [OracleFacet] = []
        for provider in list {
            if providers[provider.facet] == nil {
                providers[provider.facet] = provider
            } else if !duplicates.contains(provider.facet) {
                duplicates.append(provider.facet)
            }
        }
        self.providers = providers
        self.duplicates = duplicates
    }

    /// The facets this build has a provider for, in catalog order.
    public var provided: [OracleFacet] { OracleFacet.allCases.filter { providers[$0] != nil } }

    /// `facet`'s change signal, nil when its provider gives none (``OracleFacetProvider/changes``).
    public func changes(_ facet: OracleFacet) -> OracleFacetChanges? { providers[facet]?.changes }

    /// The facets a request names (`facets: [String]`), or every facet when it names none.
    /// An unknown name is an error: a typo must not turn into a facet nobody compares.
    public static func requested(_ names: [String]?) throws(OracleRequestError) -> [OracleFacet] {
        guard let names else { return OracleFacet.allCases }
        var facets: [OracleFacet] = []
        for name in names {
            guard let facet = OracleFacet(rawValue: name) else { throw .unknownFacet(name) }
            if !facets.contains(facet) { facets.append(facet) }
        }
        return facets
    }

    /// Every facet with its task and whether this build provides it (`debug.oracle.snapshot`
    /// with `list: true`).
    public var catalog: OracleValue {
        .array(OracleFacet.allCases.map { facet -> OracleValue in
            ["facet": .string(facet.rawValue), "provided": .bool(providers[facet] != nil), "task": .string(facet.task)]
        })
    }

    /// `{<facet>: <value>}` for every facet in `facets`, all read in this one main-actor turn.
    @MainActor
    public func snapshot(_ facets: [OracleFacet]) throws(OracleSnapshotError) -> OracleValue {
        var values: [String: OracleValue] = [:]
        for facet in facets {
            guard let provider = providers[facet] else {
                values[facet.rawValue] = .notComparable(reason: "no provider for \(facet.rawValue) in this build", task: facet.task)
                continue
            }
            do throws(OracleFacetError) {
                values[facet.rawValue] = try provider.read()
            } catch {
                throw OracleSnapshotError(facet: facet, error: error)
            }
        }
        return .object(values)
    }
}
#endif
