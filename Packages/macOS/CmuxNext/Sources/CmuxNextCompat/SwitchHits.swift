/// Every guarded refactor-switch site's count of the arm it ran, for `debug.oracle.switch_hits`
/// (p15-oracle-027, plans/cmux-next/chrome-parity/p15-oracle.md section 3F.2). The composition root
/// owns the one value and hands each site its ``RefactorSwitchHit``; there is no shared instance.
///
/// It counts only in builds that serve `debug.*` methods (`counting`, the router's
/// `debugMethodsAllowed`): elsewhere ``hit(_:site:)`` hands out a hit that counts nothing and no
/// counter is made.
///
/// One counter per site name, not per instance: every host view's layer hosting counts into the
/// same `CEFLayerHosting.pageShown` row. A site that registered and never ran reports 0 on both arms,
/// which the oracle reads as `arm-not-exercised` for that switch.
@MainActor
public final class SwitchHits {
    /// One switch's counts: the sum over its sites, and each site's.
    public struct Entry: Equatable, Sendable {
        public var old = 0
        public var new = 0
        /// Site name to its (old, new) counts.
        public var sites: [String: Arms] = [:]
    }

    /// One site's counts per arm.
    public struct Arms: Equatable, Sendable {
        public var old: Int
        public var new: Int

        public init(old: Int, new: Int) {
            self.old = old
            self.new = new
        }
    }

    private struct Site: Hashable {
        let key: RefactorSwitchKey
        let name: String
    }

    public let counting: Bool
    private var counters: [Site: RefactorSwitchHitCounter] = [:]

    public init(counting: Bool) {
        self.counting = counting
    }

    /// The hit a site of `key` counts with: the same counter for every call with this site name.
    public func hit(_ key: RefactorSwitchKey, site name: StaticString) -> RefactorSwitchHit {
        guard counting else { return RefactorSwitchHit(key: key) }
        let site = Site(key: key, name: name.description)
        if let counter = counters[site] { return RefactorSwitchHit(counter: counter) }
        let counter = RefactorSwitchHitCounter(key: key, site: site.name)
        counters[site] = counter
        return RefactorSwitchHit(counter: counter)
    }

    /// Switch raw value to its entry, one per switch with a registered site (a switch with none has
    /// no entry: 0 hits). `reset` starts every count at 0 after reading it.
    public func report(reset: Bool) -> [String: Entry] {
        var switches: [String: Entry] = [:]
        for (site, counter) in counters {
            let counts = counter.read(reset: reset)
            switches[site.key.rawValue, default: Entry()].old += counts.old
            switches[site.key.rawValue, default: Entry()].new += counts.new
            switches[site.key.rawValue, default: Entry()].sites[site.name] = Arms(old: counts.old, new: counts.new)
        }
        return switches
    }
}
