import Dispatch
import Foundation

/// Admission control for notifications arriving from cloud machines, applied on the Mac
/// after parsing and before attribution. A machine is untrusted: its daemon enforces
/// neither caps nor rates, and a compromised root can write anything to the link's
/// stdout. Every admitted notification can fan out to a banner, a sound, the user's
/// `cmux.json` hooks and `notifications.command` (`/bin/sh` spawns), and a phone push,
/// so the blast radius of a hostile machine has to be bounded here.
///
/// Per machine: a notification-id LRU (the daemon ledger holds 256 entries and replays
/// them in every snapshot; duplicate routes are also allowed by the protocol), a 5 s
/// identical-content window (Ghostty's own OSC dedup window), and a token bucket.
/// Fleet-wide: one more bucket so many machines cannot add up to a flood. The bucket
/// arithmetic mirrors `ControlClientRateLimiter` so the two limiters read the same.
struct CloudMachineNotificationGate {
    enum Decision: Equatable, Sendable {
        case allowed
        case duplicateID
        case identicalContent
        case machineRate
        case fleetRate
    }

    struct Configuration: Equatable, Sendable {
        var machineBurst: Int = 5
        var machineRefillIntervalNanoseconds: UInt64 = 1_000_000_000
        var fleetBurst: Int = 30
        var fleetRefillIntervalNanoseconds: UInt64 = 100_000_000
        var identicalContentWindowNanoseconds: UInt64 = 5_000_000_000
        var seenIDCapacity: Int = 256
        var contentKeyCapacity: Int = 64

        init() {}
    }

    private struct TokenBucket {
        var tokens: Int
        var lastRefill: UInt64
        let burst: Int
        let refillInterval: UInt64

        init(burst: Int, refillInterval: UInt64, now: UInt64) {
            self.burst = max(1, burst)
            self.refillInterval = max(1, refillInterval)
            tokens = self.burst
            lastRefill = now
        }

        mutating func refill(now: UInt64) {
            let elapsed = now >= lastRefill ? now - lastRefill : 0
            guard elapsed >= refillInterval else { return }
            let additions = Int(clamping: elapsed / refillInterval)
            tokens = min(burst, tokens + additions)
            lastRefill = now
        }

        var hasToken: Bool { tokens > 0 }

        mutating func take() { tokens -= 1 }
    }

    private struct ContentKey: Hashable {
        let terminalID: String?
        let title: String
        let body: String
    }

    private struct MachineState {
        var seenIDs: [String] = []
        var seenIDSet: Set<String> = []
        var lastContentAt: [ContentKey: UInt64] = [:]
        var bucket: TokenBucket
    }

    private let configuration: Configuration
    private let now: () -> UInt64
    private var machines: [String: MachineState] = [:]
    private var fleetBucket: TokenBucket

    init(
        configuration: Configuration = Configuration(),
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.configuration = configuration
        self.now = now
        fleetBucket = TokenBucket(
            burst: configuration.fleetBurst,
            refillInterval: configuration.fleetRefillIntervalNanoseconds,
            now: now()
        )
    }

    /// Admits or drops one event. Tokens are only consumed by admitted events, so a
    /// replayed or duplicated notification never eats into a machine's budget.
    mutating func admit(machineID: String, event: CloudMachineNotificationEvent) -> Decision {
        let current = now()
        var state = machines[machineID] ?? MachineState(
            bucket: TokenBucket(
                burst: configuration.machineBurst,
                refillInterval: configuration.machineRefillIntervalNanoseconds,
                now: current
            )
        )
        defer { machines[machineID] = state }

        guard !state.seenIDSet.contains(event.id) else { return .duplicateID }
        let contentKey = ContentKey(terminalID: event.terminalID, title: event.title, body: event.body)
        if let lastAt = state.lastContentAt[contentKey],
           current >= lastAt,
           current - lastAt < configuration.identicalContentWindowNanoseconds {
            remember(id: event.id, in: &state)
            return .identicalContent
        }
        state.bucket.refill(now: current)
        guard state.bucket.hasToken else { return .machineRate }
        fleetBucket.refill(now: current)
        guard fleetBucket.hasToken else { return .fleetRate }

        state.bucket.take()
        fleetBucket.take()
        remember(id: event.id, in: &state)
        state.lastContentAt[contentKey] = current
        if state.lastContentAt.count > configuration.contentKeyCapacity {
            let window = configuration.identicalContentWindowNanoseconds
            state.lastContentAt = state.lastContentAt.filter { current >= $0.value && current - $0.value < window }
            if state.lastContentAt.count > configuration.contentKeyCapacity {
                state.lastContentAt = [contentKey: current]
            }
        }
        return .allowed
    }

    private func remember(id: String, in state: inout MachineState) {
        guard !state.seenIDSet.contains(id) else { return }
        state.seenIDs.append(id)
        state.seenIDSet.insert(id)
        while state.seenIDs.count > configuration.seenIDCapacity {
            let evicted = state.seenIDs.removeFirst()
            state.seenIDSet.remove(evicted)
        }
    }
}
