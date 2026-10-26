#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextOracle
import CmuxNextSettings

/// The `topology` facet: the `snapshot.get` result as is (schemas/oracle/snapshot-v1.schema.json), read the
/// way `snapshot.get` reads it, from the router's snapshot store after it builds a stale snapshot
/// (``ControlSnapshotStore/fresh()``), and encoded by the same members (``ControlSnapshot/snapshotGetMembers``).
/// The runner sends no caller params, so `caller` and `beside` are absent from both.
///
/// The control router owns the snapshot, so every server with a router (the app, the headless services)
/// gets this facet where it registers the oracle (``OracleControl/init(host:snapshots:)``).
public struct OracleTopologyFacet: OracleFacetProvider {
    public var facet: OracleFacet { .topology }
    public let capture: OracleFacetCapture

    public init(snapshots: ControlSnapshotStore) {
        capture = .background { () async throws(OracleFacetError) -> OracleValue in
            OracleControl.oracle(.object(await snapshots.fresh().snapshotGetMembers))
        }
    }
}
#endif
