#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat

/// Hang injection, Debug and bench builds only (p09-observability-088): `debug.hang_inject` arms one registered
/// lane by name, and the next scope that lane opens keeps its thread busy for the armed time inside that scope,
/// so the monitor reports the lane's real thread, budget and stack once. Chrome hangs a target thread the same way
/// for its own checks: `chrome://uithreadhang` runs the hang on the thread itself
/// (content/browser/renderer_host/debug_urls.cc, `HangCurrentThread`).
///
/// One lane is armed at a time. While nothing is armed, a scope's cost is one relaxed load.
final class HangInjection: Sendable {
    /// The armed lane's packed name (``HangWatch/pack(_:)``, the registration's literal); 0: nothing armed.
    let armedName = Atomic<UInt64>(0)
    /// How long the armed lane's next scope stays busy, in nanoseconds; written before ``armedName``.
    let busyNanos = Atomic<UInt64>(0)

    /// Takes the arm when it is for the lane named `name`, then stays busy inside the caller's open scope.
    @inline(__always)
    func holdIfArmed(name: UInt64, clock: TraceClock) {
        let armed = armedName.load(ordering: .relaxed)
        guard armed != 0, armed == name else { return }
        hold(armed, clock: clock)
    }

    @inline(never)
    private func hold(_ armed: UInt64, clock: TraceClock) {
        guard armedName.compareExchange(expected: armed, desired: 0, ordering: .acquiringAndReleasing).exchanged else { return }
        let end = clock.nowNanos() &+ busyNanos.load(ordering: .relaxed)
        // The injected hang: the thread stays busy, so its stack sample shows this frame under the lane's work.
        while clock.nowNanos() < end {}
    }
}
#endif

#if DEBUG || CMUX_BENCH_HOOKS
extension HangWatch {
    /// Why ``armHang(lane:busyFor:)`` refused.
    public enum HangInjectError: Error, Equatable, Sendable {
        /// No live registration has this name.
        case unknownLane(String)
        /// A lane is armed already (one at a time); its name.
        case alreadyArmed(String)
        /// The time is not above zero and at most ``maxInjectedHang``.
        case badDuration
    }

    /// The longest hang one arm may ask for.
    public static let maxInjectedHang: Duration = .seconds(30)

    /// The names of the live registrations, each once, sorted.
    public var registeredNames: [String] {
        Set(livePackedNames().map { Self.unpack($0) }).sorted()
    }

    /// The armed lane's name; nil when nothing is armed (or its arm was taken).
    public var armedHang: String? {
        let armed = injection.armedName.load(ordering: .acquiring)
        return armed == 0 ? nil : Self.unpack(armed)
    }

    /// Arms the registered lane `lane`: the next scope it opens stays busy for `busy` inside that scope.
    ///
    /// - Throws: ``HangInjectError`` for an unknown lane, a lane armed already or a time out of range.
    public func armHang(lane: String, busyFor busy: Duration) throws(HangInjectError) {
        guard busy > .zero, busy <= Self.maxInjectedHang else { throw .badDuration }
        guard let packed = livePackedNames().first(where: { Self.unpack($0) == lane }) else { throw .unknownLane(lane) }
        let earlier = injection.armedName.load(ordering: .acquiring)
        guard earlier == 0 else { throw .alreadyArmed(Self.unpack(earlier)) }
        injection.busyNanos.store(Self.nanos(busy), ordering: .relaxed)
        let (armed, current) = injection.armedName.compareExchange(expected: 0, desired: packed, ordering: .acquiringAndReleasing)
        guard armed else { throw .alreadyArmed(Self.unpack(current)) }
    }

    /// Disarms the armed lane.
    ///
    /// - Returns: The lane it disarmed; nil when nothing was armed.
    @discardableResult
    public func disarmHang() -> String? {
        let armed = injection.armedName.exchange(0, ordering: .acquiringAndReleasing)
        return armed == 0 ? nil : Self.unpack(armed)
    }

    /// The packed name of every live registration.
    private func livePackedNames() -> [UInt64] {
        (0..<min(claimedEnd.load(ordering: .acquiring), Self.capacity)).compactMap { index in
            guard let slot = slot(at: index),
                  Self.word(slot, Self.stateWord).load(ordering: .acquiring) & Self.kindMask != 0 else { return nil }
            let packed = Self.word(slot, Self.nameWord).load(ordering: .relaxed)
            return packed == 0 ? nil : packed
        }
    }
}
#endif
