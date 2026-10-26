import CmuxNextCloud
import Foundation
import Observation

/// Settings > Machines' "Dedicated agent machine" switch on a Cloud machine (``CloudVmHost``):
/// what each machine last said, read once when its row first shows while it is connected, and
/// again only after a failed read is a minute old (no timer: the next time the row is drawn). A
/// set answers with the new state. Only machines the legacy Cloud API can exec on: an app-server
/// machine has no exec route, so its row shows no switch.
@MainActor
@Observable
final class CloudVmHostStore {
    enum Entry: Equatable {
        case known(CloudVmHost.State)
        /// The read or the last set failed: why, and when (a read is tried again a minute later).
        case failed(String, at: ContinuousClock.Instant, last: CloudVmHost.State?)
    }

    private(set) var entries: [String: Entry] = [:]
    /// The machines a set is running on (the switch is disabled meanwhile).
    private(set) var setting: Set<String> = []
    /// Reads under way. Not observed: a read starts while the page's host lists are being built
    /// (inside their observation), so it changes nothing observed until it answers.
    @ObservationIgnored private var reading: Set<String> = []
    /// Sets started per machine: a read that a set overtook drops its answer.
    @ObservationIgnored private var sets: [String: Int] = [:]
    @ObservationIgnored private let exec: @Sendable (_ machineID: String, _ command: String) async throws -> CloudExecResult
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    static let retryAfter: Duration = .seconds(60)

    init(exec: @escaping @Sendable (String, String) async throws -> CloudExecResult,
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.exec = exec
        self.now = now
    }

    convenience init(api: CloudAPIClient) {
        self.init(exec: { id, command in try await api.exec(id, command: command, timeoutMs: CloudVmHost.timeoutMs) })
    }

    /// The row's state for `machineID`, starting its read when none is known (or the last failed
    /// a minute ago) and `readable` (connected, with exec). Nil until the first answer.
    func state(_ machineID: String, readable: Bool) -> Entry? {
        let entry = entries[machineID]
        let stale: Bool = switch entry {
        case nil: true
        case .failed(_, let at, _): now() - at >= Self.retryAfter
        default: false
        }
        if stale, readable, !setting.contains(machineID), !reading.contains(machineID) { read(machineID) }
        return entry
    }

    private func read(_ machineID: String) {
        let last = Self.known(entries[machineID])
        reading.insert(machineID)
        let started = sets[machineID, default: 0]
        let exec = exec, now = now
        Task { @MainActor [weak self] in
            let entry: Entry
            do {
                let ran = try await exec(machineID, CloudVmHost.command(on: nil))
                entry = CloudVmHost.parse(ran).map(Entry.known) ?? .failed(CloudVmHost.failure(ran), at: now(), last: last)
            } catch {
                entry = .failed(String(describing: error), at: now(), last: last)
            }
            guard let self else { return }
            reading.remove(machineID)
            if sets[machineID, default: 0] == started { entries[machineID] = entry }
        }
    }

    /// Turns the setting on or off on `machineID`: the error to show, or nil.
    func set(_ machineID: String, on: Bool) async -> String? {
        guard !setting.contains(machineID) else { return nil }
        setting.insert(machineID)
        sets[machineID, default: 0] += 1
        defer { setting.remove(machineID) }
        let last = Self.known(entries[machineID])
        do {
            let ran = try await exec(machineID, CloudVmHost.command(on: on))
            if let state = CloudVmHost.parse(ran) {
                entries[machineID] = .known(state)
                return nil
            }
            let why = CloudVmHost.failure(ran)
            entries[machineID] = .failed(why, at: now(), last: last)
            return why
        } catch {
            let why = String(describing: error)
            entries[machineID] = .failed(why, at: now(), last: last)
            return why
        }
    }

    /// Forgets a machine that left the registry.
    func forget(keeping machineIDs: Set<String>) {
        entries = entries.filter { machineIDs.contains($0.key) }
    }

    private static func known(_ entry: Entry?) -> CloudVmHost.State? {
        switch entry {
        case .known(let state): state
        case .failed(_, _, let last): last
        default: nil
        }
    }
}
