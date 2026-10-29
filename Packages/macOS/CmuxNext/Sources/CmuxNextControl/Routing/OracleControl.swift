#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextOracle
import CmuxNextSettings

/// `debug.oracle.snapshot` over the one facet list a composition root builds (``OracleHost``): only the
/// `overlays` facet stays, for the Chromium Host find rows. DEV and bench builds only: a Release build
/// compiles none of this, and its router answers every `debug.oracle.*` name `not_allowed`
/// (``ControlRouter/releaseRefusedDebugPrefixes``), so a runner tells a refusing build from an older one.
public struct OracleControl: Sendable {
    public static let snapshot = "debug.oracle.snapshot"

    public let facets: OracleFacets

    public init(facets: OracleFacets) {
        self.facets = facets
    }

    /// The methods over the host's list, built once here.
    @MainActor
    public init(host: some OracleHost) {
        self.init(facets: host.makeOracleFacets())
    }

    public var methods: [ControlMethod] {
        [
            // Params: `facets` (facet names; all when absent) and `list` (the catalog: every facet, its
            // task, and whether this build provides it). The result is `{<facet>: <value>}`. The
            // main-actor facets are read in this one turn; the background facets after it, off the main actor.
            .mainActor(Self.snapshot) { [facets] call in
                if call.params["list"]?.boolValue == true { return .value(Self.json(facets.catalog)) }
                let requested: [OracleFacet]
                do throws(OracleRequestError) {
                    requested = try OracleFacets.requested(try Self.names(call.params["facets"]))
                } catch {
                    throw ControlError.invalidParams(error.message, data: ["param": "facets"])
                }
                let capture: OracleCapture
                do throws(OracleSnapshotError) {
                    capture = try facets.beginCapture(requested)
                } catch {
                    throw Self.failure(error)
                }
                if let completed = capture.completed { return .value(Self.json(completed)) }
                return .followUp {
                    do throws(OracleSnapshotError) {
                        return Self.json(try await capture.finish())
                    } catch {
                        throw Self.failure(error)
                    }
                }
            },
        ]
    }

    /// The `facets` param: nil when absent, else a list of facet names.
    private static func names(_ param: JSONValue?) throws(OracleRequestError) -> [String]? {
        guard let param, !param.isNull else { return nil }
        guard case .array(let items) = param else { throw .notAList }
        var names: [String] = []
        for item in items {
            guard let name = item.stringValue else { throw .notAList }
            names.append(name)
        }
        return names
    }

    private static func failure(_ error: OracleSnapshotError) -> ControlError {
        ControlError(code: "internal_error", message: error.message, data: ["facet": .string(error.facet.rawValue)])
    }

    /// The facet value as the control socket's JSON, converted once at the answer.
    static func json(_ value: OracleValue) -> JSONValue {
        switch value {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .number(let number): .number(number)
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(json))
        case .object(let members): .object(members.mapValues(json))
        }
    }
}
#endif
