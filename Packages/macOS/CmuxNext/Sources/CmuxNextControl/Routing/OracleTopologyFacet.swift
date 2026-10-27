#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextOracle
import CmuxNextSettings

/// The `topology` facet: the `snapshot.get` result as is (schemas/oracle/snapshot-v1.schema.json), from the
/// router's snapshot store and encoded by the same members (``ControlSnapshot/snapshotGetMembers``). The runner
/// sends no caller params, so `caller` and `beside` are absent from both.
///
/// A main-actor facet: the snapshot is read, and built first when stale (``ControlSnapshotStore/freshNow()``),
/// in the turn that reads the other main-actor facets, so the topology and those facets describe one model
/// state. The app registers it with the oracle (``OracleControl/init(host:snapshots:)``).
public struct OracleTopologyFacet: OracleFacetProvider {
    public var facet: OracleFacet { .topology }
    public let capture: OracleFacetCapture

    public init(snapshots: ControlSnapshotStore) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            OracleControl.oracle(.object(snapshots.freshNow().snapshotGetMembers))
        }
    }
}
#endif
