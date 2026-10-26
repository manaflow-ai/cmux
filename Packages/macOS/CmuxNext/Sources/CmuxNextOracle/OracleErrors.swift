#if DEBUG || CMUX_BENCH_HOOKS
/// A provider could not build its facet from a state it should handle. A facet the build has no
/// source for is not an error: the provider returns ``OracleValue/notComparable(reason:task:)``.
public struct OracleFacetError: Error, Sendable, Hashable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

/// A snapshot failed because one of its facets did: the whole snapshot fails, so a broken
/// provider is never recorded as a value the diff could match.
public struct OracleSnapshotError: Error, Sendable, Hashable {
    public let facet: OracleFacet
    public let error: OracleFacetError

    public init(facet: OracleFacet, error: OracleFacetError) {
        self.facet = facet
        self.error = error
    }

    public var message: String { "facet \(facet.rawValue): \(error.message)" }
}

/// A `debug.oracle.snapshot` request the oracle cannot answer.
public enum OracleRequestError: Error, Sendable, Hashable {
    case unknownFacet(String)
    /// `facets` is not a list of facet names.
    case notAList

    public var message: String {
        switch self {
        case .unknownFacet(let name): "unknown oracle facet \(name)"
        case .notAList: "facets must be a list of facet names"
        }
    }
}
#endif
