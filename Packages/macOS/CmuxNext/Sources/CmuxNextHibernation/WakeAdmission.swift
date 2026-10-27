package import CmuxNextCompat
import Foundation
import Observation

/// Admission control for page wakes nobody asked for, after Chrome's `BackgroundTabLoadingPolicy`
/// (chrome/browser/performance_manager/policies/background_tab_loading_policy.cc):
///
/// - An automation or prewarm wake (an agent's or a script's call on a hibernated page, a neighbor
///   or hovered tab woken early) starts only while fewer than ``limit`` of them restore:
///   clamp(cores / 2, 1, 4) (Chrome's `kCoresPerSimultaneousTabLoad` 2, `kMinSimultaneousTabLoads` 1,
///   `kMaxSimultaneousTabLoads` 4). The rest wait in order.
/// - At warning or critical memory pressure none starts and the waiting ones are dropped, each with a
///   typed ``Deferral`` (Chrome stops background loading at moderate pressure). A page woken under
///   pressure would be discarded again at once: this stops the discard/wake loop.
/// - None starts while the system has less than ``freeFloorBytes`` free (Chrome's
///   `kDesiredAmountOfFreeMemoryMb` 150).
/// - A person's show, press or Wake Tab is never queued: it restores at once and takes no slot (the
///   policy only governs background loads). A released agent chat page is built again only when its tab
///   shows (the app's `AgentPageHibernation`), so it never comes here.
///
/// Off (feature `memoryWakeAdmission`, default off) every wake starts at once, as before. Event-driven:
/// a request, a restore ending and a pressure change are the only inputs; there is no timer.
@MainActor @Observable
package final class WakeAdmission {
    /// Who asked for a wake.
    package enum Requester: String, Sendable {
        /// A person's show, press or Wake Tab: always starts at once.
        case person
        /// An agent's or a script's call on a hibernated page (`cmux browser`, MCP, the browser REPL,
        /// DevTools): it needs the page, but nobody looks at it.
        case automation
        /// A neighbor or hovered tab woken early, so the next switch shows a live page.
        case prewarm
    }

    /// Why a wake nobody asked for did not start.
    package enum Deferral: String, Error, Sendable, Equatable {
        /// Memory pressure is warning or critical.
        case memoryPressure
        /// The system has less than ``WakeAdmission/freeFloorBytes`` free.
        case lowFreeMemory
    }

    /// What a wake request did.
    package enum Outcome: Equatable, Sendable {
        /// The restore runs now.
        case started
        /// It waits for a slot: it starts when a restore ends, or is dropped with a deferral.
        case queued
        /// It did not start and will not (``deferral(of:)`` keeps the reason until the next request).
        case deferred(Deferral)
        /// The page was not hibernated: nothing to wake.
        case notHibernated
    }

    /// A wake waiting for a slot.
    package struct Waiting: Equatable, Sendable {
        package let key: String
        package var requester: Requester
    }

    /// What one pump did: the waiting wakes to restore now, oldest first, and the ones dropped.
    package struct Pump: Equatable, Sendable {
        package var starts: [Waiting] = []
        package var deferred: [String: Deferral] = [:]

        package init() {}
    }

    /// Chrome's `kDesiredAmountOfFreeMemoryMb`.
    package static let freeFloorBytes: UInt64 = 150 * 1024 * 1024

    /// clamp(cores / 2, 1, 4): Chrome's `GetMaxSimultaneousTabLoads` with its defaults.
    package nonisolated static func limit(cores: Int) -> Int {
        min(max(cores / 2, 1), 4)
    }

    package let isEnabled: Bool
    /// Unrequested wakes that may restore at once.
    package let limit: Int
    /// Bytes the system has free now; nil when unreadable (then the floor holds no wake back).
    private let freeBytes: () -> UInt64?
    /// Unrequested wakes restoring now.
    @ObservationIgnored package private(set) var restoring: Set<String> = []
    /// Unrequested wakes waiting for a slot, oldest first.
    @ObservationIgnored package private(set) var waiting: [Waiting] = []
    /// The last deferral of each tab, until its next request or its close. Observed: an agent's wait on a
    /// queued wake ends when the wake is dropped.
    private var deferrals: [String: Deferral] = [:]

    /// - Parameters:
    ///   - isEnabled: The `memoryWakeAdmission` feature; off, every request starts.
    ///   - cores: The Mac's active cores (Chrome's `base::SysInfo::NumberOfProcessors`).
    ///   - freeBytes: Reads the system's free bytes, once per admission decision; nil when unreadable.
    package init(isEnabled: Bool, cores: Int = ProcessInfo.processInfo.activeProcessorCount, freeBytes: @escaping () -> UInt64?) {
        self.isEnabled = isEnabled
        limit = Self.limit(cores: cores)
        self.freeBytes = freeBytes
    }

    /// Why tab `key`'s last unrequested wake did not start; nil when it started, waits or none was asked.
    package func deferral(of key: String) -> Deferral? { deferrals[key] }

    /// Asks to wake hibernated tab `key`. `.started` means the caller restores it now.
    package func request(_ key: String, by requester: Requester, pressure: MemoryPressureLevel) -> Outcome {
        if deferrals[key] != nil { deferrals[key] = nil }
        guard isEnabled, requester != .person else {
            waiting.removeAll { $0.key == key }
            return .started
        }
        if pressure != .normal { return deferWake(key, .memoryPressure) }
        if let index = waiting.firstIndex(where: { $0.key == key }) {
            // An agent that needs a page a prewarm asked for keeps it from being cancelled as a neighbor.
            if requester == .automation { waiting[index].requester = .automation }
            return .queued
        }
        guard restoring.count < limit else {
            waiting.append(Waiting(key: key, requester: requester))
            return .queued
        }
        if let free = freeBytes(), free < Self.freeFloorBytes { return deferWake(key, .lowFreeMemory) }
        restoring.insert(key)
        return .started
    }

    /// Tab `key`'s wake ended (its restore failed or was superseded, or its page loaded) or the tab closed:
    /// frees its slot and starts the next waiting wakes. `isHibernated` skips waiting tabs that woke another
    /// way (a person showed one) or closed meanwhile.
    package func finished(_ key: String, pressure: MemoryPressureLevel, isHibernated: (String) -> Bool) -> Pump {
        restoring.remove(key)
        waiting.removeAll { $0.key == key }
        return pump(pressure: pressure, isHibernated: isHibernated)
    }

    /// A waiting prewarm of tab `key` is no longer wanted (it stopped being a neighbor). A waiting
    /// automation wake stays: an agent still waits for that page.
    package func cancelPrewarm(_ key: String) {
        waiting.removeAll { $0.key == key && $0.requester == .prewarm }
    }

    /// Tab `key` closed: its deferral goes (its slot and place end through ``finished(_:pressure:isHibernated:)``).
    package func forget(_ key: String) {
        if deferrals[key] != nil { deferrals[key] = nil }
    }

    /// Memory pressure changed: above normal, every waiting wake is dropped.
    package func pressureDidChange(_ pressure: MemoryPressureLevel) -> Pump {
        pressure == .normal ? Pump() : dropWaiting(.memoryPressure)
    }

    private func pump(pressure: MemoryPressureLevel, isHibernated: (String) -> Bool) -> Pump {
        waiting.removeAll { !isHibernated($0.key) }
        guard restoring.count < limit, !waiting.isEmpty else { return Pump() }
        // Only a restore's end pumps: a wake kept waiting with a slot free would wait for an event that may never come.
        if pressure != .normal { return dropWaiting(.memoryPressure) }
        if let free = freeBytes(), free < Self.freeFloorBytes { return dropWaiting(.lowFreeMemory) }
        var pump = Pump()
        while restoring.count < limit, !waiting.isEmpty {
            let entry = waiting.removeFirst()
            restoring.insert(entry.key)
            pump.starts.append(entry)
        }
        return pump
    }

    private func dropWaiting(_ reason: Deferral) -> Pump {
        guard !waiting.isEmpty else { return Pump() }
        var pump = Pump()
        for entry in waiting {
            pump.deferred[entry.key] = reason
            deferrals[entry.key] = reason
        }
        waiting.removeAll()
        return pump
    }

    private func deferWake(_ key: String, _ reason: Deferral) -> Outcome {
        waiting.removeAll { $0.key == key }
        deferrals[key] = reason
        return .deferred(reason)
    }
}
