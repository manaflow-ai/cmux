#if DEBUG || CMUX_BENCH_HOOKS
/// The composition root's side of the oracle (AppServices): it builds the
/// one ``OracleFacets`` list, with a provider over each model it owns. The control methods ask for it
/// once, when they are registered; there is no shared registry (p15-oracle.md section 4, rule 4).
@MainActor
public protocol OracleHost: AnyObject {
    func makeOracleFacets() -> OracleFacets
}
#endif
