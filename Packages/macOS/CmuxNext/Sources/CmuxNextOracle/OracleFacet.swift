#if DEBUG || CMUX_BENCH_HOOKS
/// A facet of the `debug.oracle.snapshot` answer. Only `overlays` stays: the Chromium Host find rows
/// (scripts/cmux-next/chromium_host_find.py) read its `findBar`. The other facets of the refactor oracle
/// (p15-oracle) were removed in deletion wave 1; the overlays facet goes with host mode.
public enum OracleFacet: String, Sendable, Hashable, CaseIterable {
    case overlays

    /// The task that wrote this facet's provider; a facet with no provider in this build is answered
    /// not-comparable with this task.
    public var task: String {
        switch self {
        case .overlays: "p15-oracle-038"
        }
    }
}
#endif
