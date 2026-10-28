/// Every guarded refactor-switch site's count of the arm it ran, for `debug.oracle.switch_hits`
/// (plans/cmux-next/chrome-parity/p15-oracle.md section 3F.2). The composition root
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
    /// The `debug.oracle.switch_hits` reply, encoded as is:
    /// `{"switches": {KEY: {"old": N, "new": N, "sites": {SITE: {"old": N, "new": N}}}}}`.
    /// `scripts/cmux-next/oracle/switches.py --hits` reads this shape; both sides test it against
    /// `schemas/oracle/fixtures/switch-hits-reply.json`.
    public struct Report: Codable, Equatable, Sendable {
        /// Switch registry key to its entry, one per switch with a registered site (a switch with
        /// none has no entry: 0 hits).
        public var switches: [String: Entry]

        public init(switches: [String: Entry]) {
            self.switches = switches
        }
    }

    /// One switch's counts: the sum over its sites, and each site's.
    public struct Entry: Codable, Equatable, Sendable {
        public var old: Int
        public var new: Int
        /// Site name to its (old, new) counts.
        public var sites: [String: Arms]

        public init(old: Int = 0, new: Int = 0, sites: [String: Arms] = [:]) {
            self.old = old
            self.new = new
            self.sites = sites
        }
    }

    /// One site's counts per arm.
    public struct Arms: Codable, Equatable, Sendable {
        public var old: Int
        public var new: Int

        public init(old: Int, new: Int) {
            self.old = old
            self.new = new
        }
    }

    private struct Site: Hashable {
        let key: String
        let name: String
    }

    public let counting: Bool
    private var counters: [Site: RefactorSwitchHitCounter] = [:]

    public init(counting: Bool) {
        self.counting = counting
    }

    /// The hit a site of `key` counts with: the same counter for every call with this site name.
    /// `key` is the switch's catalog case (`RefactorSwitchKey`); its raw value is the registry key.
    public func hit<Key: RawRepresentable>(_ key: Key, site name: StaticString) -> RefactorSwitchHit
        where Key.RawValue == String {
        guard counting else { return RefactorSwitchHit(key: key.rawValue) }
        let site = Site(key: key.rawValue, name: name.description)
        if let counter = counters[site] { return RefactorSwitchHit(counter: counter) }
        let counter = RefactorSwitchHitCounter(key: site.key, site: site.name)
        counters[site] = counter
        return RefactorSwitchHit(counter: counter)
    }

    /// The counts of every registered site, per switch. `reset` starts every count at 0 after
    /// reading it.
    public func report(reset: Bool) -> Report {
        var switches: [String: Entry] = [:]
        for (site, counter) in counters {
            let counts = counter.read(reset: reset)
            switches[site.key, default: Entry()].old += counts.old
            switches[site.key, default: Entry()].new += counts.new
            switches[site.key, default: Entry()].sites[site.name] = Arms(old: counts.old, new: counts.new)
        }
        return Report(switches: switches)
    }
}
