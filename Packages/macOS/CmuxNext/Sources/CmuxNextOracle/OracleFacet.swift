#if DEBUG || CMUX_BENCH_HOOKS
/// A facet of the oracle snapshot (plans/cmux-next/chrome-parity/p15-oracle.md section 3A). The raw
/// value is the facet's key in schemas/oracle/snapshot-v1.schema.json. `daemon` is not here: the
/// runner reads it from the daemon itself (`session.snapshot`, `settings.snapshot`, `oracle-state`).
public enum OracleFacet: String, Sendable, Hashable, CaseIterable {
    case topology
    case focus
    case layout
    case sidebar
    case tabs
    case overlays
    case settings
    case intents
    case windows
    case history
    case notifications
    case agents
    case terminals
    case webviews
    case ax
    case crashes
    case liveObjects
    case invariants
    case switches

    /// The task that writes this facet's provider: the schema's `x-oracle-source.task`
    /// (scripts/cmux-next/oracle/facet_catalog_test.py checks the two agree). A facet with no
    /// provider in this build is answered not-comparable with this task.
    public var task: String {
        switch self {
        case .switches: "p15-oracle-027"
        case .topology, .invariants: "p15-oracle-033"
        case .focus: "p15-oracle-034"
        case .layout: "p15-oracle-035"
        case .sidebar: "p15-oracle-036"
        case .tabs: "p15-oracle-037"
        case .overlays: "p15-oracle-038"
        case .settings: "p15-oracle-039"
        case .intents: "p15-oracle-040"
        case .windows: "p15-oracle-041"
        case .history, .notifications: "p15-oracle-042"
        case .agents: "p15-oracle-043"
        case .terminals: "p15-oracle-044"
        case .crashes, .liveObjects: "p15-oracle-188"
        case .webviews: "p15-oracle-215"
        case .ax: "p15-oracle-216"
        }
    }
}
#endif
