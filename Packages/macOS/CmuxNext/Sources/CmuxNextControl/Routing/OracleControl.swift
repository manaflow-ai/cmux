#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextOracle
import CmuxNextSettings

/// The refactor oracle's control methods (plans/cmux-next/chrome-parity/p15-oracle.md section 3A) over
/// the one facet list a composition root builds (``OracleHost``). DEV and bench builds only: a Release
/// build compiles none of this, and its router answers every `debug.oracle.*` name `not_allowed`
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

    /// The methods over the host's list and the router's own facet, the topology of `snapshots`
    /// (``OracleTopologyFacet``): what a server registers on its router.
    @MainActor
    public init(host: some OracleHost, snapshots: ControlSnapshotStore) {
        self.init(facets: host.makeOracleFacets().adding([OracleTopologyFacet(snapshots: snapshots)]))
    }

    public var methods: [ControlMethod] {
        [
            // Params: `facets` (facet names; all when absent), `list` (the catalog: every facet, its
            // task, and whether this build provides it), `paths` (`{root: [String], home: [String]}`, the
            // prefixes normalize.py gets as `--root` and `--home`: a hashed path field rewrites them to
            // `$ROOT` and `$HOME` before the hash). The result is `{<facet>: <value>}`
            // (schemas/oracle/README.md, "Source methods"). The main-actor facets are read in this
            // one turn; the background facets after it, off the main actor.
            .mainActor(Self.snapshot) { [facets] call in
                if call.params["list"]?.boolValue == true { return .value(Self.json(facets.catalog)) }
                let requested: [OracleFacet]
                do throws(OracleRequestError) {
                    requested = try OracleFacets.requested(try Self.names(call.params["facets"]))
                } catch {
                    throw ControlError.invalidParams(error.message, data: ["param": "facets"])
                }
                let paths = try Self.paths(call.params["paths"])
                let capture: OracleCapture
                do throws(OracleSnapshotError) {
                    capture = try facets.rewriting(paths).beginCapture(requested)
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

    /// The `paths` param (`{root: [String], home: [String]}`, either list optional): no prefix when absent.
    static func paths(_ param: JSONValue?) throws(ControlError) -> OraclePaths {
        guard let param, !param.isNull else { return .unchanged }
        func prefixes(_ key: String) throws(OracleRequestError) -> [String] {
            guard let list = param[key], !list.isNull else { return [] }
            guard let items = list.arrayValue else { throw OracleRequestError.badPaths("\(key) must be a list of paths") }
            var values: [String] = []
            for item in items {
                guard let value = item.stringValue else { throw OracleRequestError.badPaths("\(key) must be a list of paths") }
                values.append(value)
            }
            return values
        }
        do throws(OracleRequestError) {
            guard case .object(let members) = param else { throw OracleRequestError.badPaths("must be an object with root and home") }
            if let extra = members.keys.first(where: { $0 != "root" && $0 != "home" }) { throw OracleRequestError.badPaths("unknown key \(extra)") }
            return try OraclePaths(root: prefixes("root"), home: prefixes("home"))
        } catch {
            throw ControlError.invalidParams(error.message, data: ["param": "paths"])
        }
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

    /// A control answer as a facet value (the topology facet is `snapshot.get`'s JSON as is).
    static func oracle(_ value: JSONValue) -> OracleValue {
        switch value {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .number(let number): .number(number)
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(oracle))
        case .object(let members): .object(members.mapValues(oracle))
        }
    }
}
#endif
