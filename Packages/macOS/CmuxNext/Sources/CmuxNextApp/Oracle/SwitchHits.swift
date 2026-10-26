#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import CmuxNextSettings

/// Every guarded refactor-switch site's count of the arm it ran, for `debug.oracle.switch_hits`
/// (p15-oracle-027). AppServices owns the one value and hands each site its ``RefactorSwitchHit``
/// (`AppServices.switchHit(_:site:)`); there is no shared instance.
///
/// One counter per site name, not per instance: every host view's layer hosting counts into the
/// same `CEFLayerHosting.pageShown` row. A site that registered and never ran reports 0 on both arms,
/// which the oracle reads as `arm-not-exercised` for that switch.
final class SwitchHits {
    private struct Site: Hashable {
        let key: RefactorSwitchKey
        let name: String
    }

    private var counters: [Site: RefactorSwitchHitCounter] = [:]

    /// The hit a site of `key` counts with; the same counter for every call with this site name.
    func hit(_ key: RefactorSwitchKey, site name: StaticString) -> RefactorSwitchHit {
        let site = Site(key: key, name: name.description)
        if let counter = counters[site] { return RefactorSwitchHit(counter: counter) }
        let counter = RefactorSwitchHitCounter(key: key, site: site.name)
        counters[site] = counter
        return RefactorSwitchHit(counter: counter)
    }

    /// `{"switches": {KEY: {"old": N, "new": N, "sites": {SITE: {"old": N, "new": N}}}}}`, one entry
    /// per switch with a registered site (a switch with none has no entry: 0 hits). `reset` starts
    /// every count at 0 after reading it.
    func report(reset: Bool) -> JSONValue {
        var switches: [String: (old: Int, new: Int, sites: [String: JSONValue])] = [:]
        for (site, counter) in counters {
            let counts = counter.read(reset: reset)
            var entry = switches[site.key.rawValue] ?? (old: 0, new: 0, sites: [:])
            entry.old += counts.old
            entry.new += counts.new
            entry.sites[site.name] = ["old": .number(Double(counts.old)), "new": .number(Double(counts.new))]
            switches[site.key.rawValue] = entry
        }
        return ["switches": .object(switches.mapValues { entry -> JSONValue in
            ["old": .number(Double(entry.old)), "new": .number(Double(entry.new)), "sites": .object(entry.sites)]
        })]
    }
}
#endif
