/// What one guarded site of a refactor switch holds next to its frozen arm: it counts the arm the
/// site ran (p15-oracle-027, plans/cmux-next/chrome-parity/p15-oracle.md section 3F.2).
///
/// The oracle reads the counts through `debug.oracle.switch_hits` and calls a run with 0 hits on the
/// requested arm `arm-not-exercised` (`scripts/cmux-next/oracle/switches.py --hits`): reading the
/// arm back proves the switch was set, a hit proves a site took that arm. Chrome does the same with
/// its frozen `FeatureList`: `FeatureList::IsEnabled` activates the feature's field trial
/// (base/feature_list.cc, `FieldTrial::Activate` in base/metrics/field_trial.cc), and only active
/// trials are reported, so a configured but never-reached arm reports nothing.
///
/// The composition root hands a site a counted hit in DEBUG and bench builds and ``init(key:)``
/// (counts nothing) in Release and tests. ``ran(new:)`` is one relaxed atomic add, safe from any
/// thread and on a per-frame path.
public struct RefactorSwitchHit: Sendable {
    public let key: RefactorSwitchKey
    private let counter: RefactorSwitchHitCounter?

    /// A hit that counts nothing.
    public init(key: RefactorSwitchKey) {
        self.key = key
        counter = nil
    }

    /// A hit that counts into `counter` (its key is this hit's).
    public init(counter: RefactorSwitchHitCounter) {
        key = counter.key
        self.counter = counter
    }

    /// Whether a ``ran(new:)`` reaches a counter.
    public var isCounted: Bool { counter != nil }

    /// The site ran the new arm (`new`) or the old one.
    @inline(__always)
    public func ran(new: Bool) {
        counter?.count(new: new)
    }
}

/// The two arm counts of one guarded site: every hit of that site, from every instance of its
/// owner, lands here.
public final class RefactorSwitchHitCounter: Sendable {
    public let key: RefactorSwitchKey
    /// The site's name, `Type.method`.
    public let site: String
    private let oldArm = Atomic<Int>(0)
    private let newArm = Atomic<Int>(0)

    public init(key: RefactorSwitchKey, site: String) {
        self.key = key
        self.site = site
    }

    @inline(__always)
    func count(new: Bool) {
        if new {
            newArm.add(1, ordering: .relaxed)
        } else {
            oldArm.add(1, ordering: .relaxed)
        }
    }

    /// The counts so far; `reset` starts both at 0 again (a case start).
    public func read(reset: Bool) -> (old: Int, new: Int) {
        if reset {
            return (oldArm.exchange(0, ordering: .relaxed), newArm.exchange(0, ordering: .relaxed))
        }
        return (oldArm.load(ordering: .relaxed), newArm.load(ordering: .relaxed))
    }
}
