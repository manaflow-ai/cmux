#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's facet providers: one immutable list the composition root builds once
/// (p15-oracle.md section 4, rule 4: no singleton, no static registry). `debug.oracle.snapshot`
/// asks it for the facets a case names; a facet with no provider in this build answers
/// not-comparable, never absent, so the diff can never pass it.
///
/// A snapshot takes one main-actor hop: ``beginCapture(_:)`` runs every main-actor provider and the
/// main-actor part of every split provider in the same turn, then ``OracleCapture/finish()`` runs the
/// background providers and the rest of the split ones off the main actor.
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

    /// Runs the main-actor providers of `facets`, and the main-actor part of the split ones, in this turn and
    /// returns the rest of the snapshot.
    @MainActor
    public func beginCapture(_ facets: [OracleFacet]) throws(OracleSnapshotError) -> OracleCapture {
        var values: [String: OracleValue] = [:]
        var background: [OracleCapture.Pending] = []
        for facet in facets {
            guard let provider = providers[facet] else {
                values[facet.rawValue] = .notComparable(reason: "no provider for \(facet.rawValue) in this build", task: facet.task)
                continue
            }
            switch provider.capture {
            case .mainActor(let read):
                do throws(OracleFacetError) {
                    values[facet.rawValue] = try read()
                } catch {
                    throw OracleSnapshotError(facet: facet, error: error)
                }
            case .background(let read):
                background.append(OracleCapture.Pending(facet: facet, read: read))
            case .split(let begin):
                do throws(OracleFacetError) {
                    background.append(OracleCapture.Pending(facet: facet, read: try begin()))
                } catch {
                    throw OracleSnapshotError(facet: facet, error: error)
                }
            }
        }
        return OracleCapture(values: values, background: background)
    }
}

/// A snapshot whose main-actor facets are read; ``finish()`` reads the background ones.
public struct OracleCapture: Sendable {
    struct Pending: Sendable {
        let facet: OracleFacet
        let read: OracleFacetRead

        func run() async -> Result<OracleValue, OracleFacetError> {
            do throws(OracleFacetError) {
                return .success(try await read())
            } catch {
                return .failure(error)
            }
        }
    }

    private let values: [String: OracleValue]
    private let background: [Pending]

    init(values: [String: OracleValue], background: [Pending]) {
        self.values = values
        self.background = background
    }

    /// The snapshot when no facet runs off the main actor.
    public var completed: OracleValue? { background.isEmpty ? .object(values) : nil }

    /// `{<facet>: <value>}` for every requested facet.
    /// The background facets read concurrently, each in its own child task.
    public func finish() async throws(OracleSnapshotError) -> OracleValue {
        let background = background
        let results: [OracleFacet: Result<OracleValue, OracleFacetError>] = await withTaskGroup(
            of: (OracleFacet, Result<OracleValue, OracleFacetError>).self
        ) { group in
            for pending in background {
                group.addTask { (pending.facet, await pending.run()) }
            }
            var results: [OracleFacet: Result<OracleValue, OracleFacetError>] = [:]
            for await (facet, result) in group { results[facet] = result }
            return results
        }
        var values = values
        // Catalog order, so the reported error does not depend on which task ended first.
        for facet in OracleFacet.allCases {
            switch results[facet] {
            case .success(let value): values[facet.rawValue] = value
            case .failure(let error): throw OracleSnapshotError(facet: facet, error: error)
            case nil: continue
            }
        }
        return .object(values)
    }
}
#endif
