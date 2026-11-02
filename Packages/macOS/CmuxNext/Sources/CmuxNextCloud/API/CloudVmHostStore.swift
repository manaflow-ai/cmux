import Foundation
public import Observation

/// Settings > Machines' "Dedicated agent machine" switch on a Cloud machine (``CloudVmHost``):
/// what each machine last said, read once when its row first shows while it is connected, and
/// again only after a failed read is a minute old (no timer: the next time the row is drawn). A
/// set answers with the new state. Only machines the legacy Cloud API can exec on: an app-server
/// machine has no exec route, so its row shows no switch. A machine that leaves the registry is
/// forgotten (``forget(_:)``), with any read or set still under way for it.
@MainActor
@Observable
public final class CloudVmHostStore {
    public enum Entry: Equatable {
        case known(CloudVmHost.State)
        /// The read or the last set failed: why, and when (a read is tried again a minute later).
        case failed(String, at: ContinuousClock.Instant, last: CloudVmHost.State?)
    }

    public private(set) var entries: [String: Entry] = [:]
    /// The machines a set is running on (the switch is disabled meanwhile).
    public private(set) var setting: Set<String> = []
    /// Reads under way: the generation each started at, and its task (``forget(_:)`` cancels
    /// it). Not observed: a read starts while the page's host lists are being built (inside
    /// their observation), so it changes nothing observed until it answers.
    @ObservationIgnored private var reading: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    /// Bumped per machine when a set starts or the machine is forgotten: a read or set that
    /// either overtook drops its answer.
    @ObservationIgnored private var generation: [String: Int] = [:]
    @ObservationIgnored private let vmHost: CloudVmHost
    @ObservationIgnored private let exec: @Sendable (_ machineID: String, _ command: String) async throws -> CloudExecResult
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    public static let retryAfter: Duration = .seconds(60)

    public init(vmHost: CloudVmHost = CloudVmHost(),
                exec: @escaping @Sendable (String, String) async throws -> CloudExecResult,
                now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.vmHost = vmHost
        self.exec = exec
        self.now = now
    }

    public convenience init(api: CloudAPIClient, vmHost: CloudVmHost = CloudVmHost()) {
        self.init(vmHost: vmHost, exec: { id, command in try await api.exec(id, command: command, timeoutMs: vmHost.timeoutMs) })
    }

    /// The row's state for `machineID`, starting its read when none is known (or the last failed
    /// a minute ago) and `readable` (connected, with exec). Nil until the first answer.
    public func state(_ machineID: String, readable: Bool) -> Entry? {
        let entry = entries[machineID]
        let stale: Bool = switch entry {
        case nil: true
        case .failed(_, let at, _): now() - at >= Self.retryAfter
        default: false
        }
        if stale, readable, !setting.contains(machineID), reading[machineID] == nil { read(machineID) }
        return entry
    }

    private func read(_ machineID: String) {
        let last = Self.known(entries[machineID])
        let started = generation[machineID, default: 0]
        let exec = exec, now = now, vmHost = vmHost
        // On the main actor, so it is stored below before its body runs.
        let task = Task { @MainActor [weak self] in
            let entry: Entry
            do {
                let ran = try await exec(machineID, vmHost.command(on: nil))
                entry = vmHost.parse(ran).map(Entry.known) ?? .failed(vmHost.failure(ran), at: now(), last: last)
            } catch {
                entry = .failed(String(describing: error), at: now(), last: last)
            }
            guard let self else { return }
            // A read for the machine after it was forgotten and came back is not this one's.
            if reading[machineID]?.generation == started { reading[machineID] = nil }
            if generation[machineID, default: 0] == started { entries[machineID] = entry }
        }
        reading[machineID] = (started, task)
    }

    /// Turns the setting on or off on `machineID`: the error to show, or nil. Nothing runs unless
    /// the machine is `reachable` now (connected, with exec): a switch drawn while it was never
    /// wakes it after (the switch is disabled then).
    public func set(_ machineID: String, on: Bool, reachable: Bool) async -> String? {
        guard reachable, !setting.contains(machineID) else { return nil }
        setting.insert(machineID)
        generation[machineID, default: 0] += 1
        let started = generation[machineID, default: 0]
        defer { setting.remove(machineID) }
        let last = Self.known(entries[machineID])
        let answer: Result<CloudVmHost.State, Failure>
        do {
            let ran = try await exec(machineID, vmHost.command(on: on))
            answer = vmHost.parse(ran).map { .success($0) } ?? .failure(Failure(why: vmHost.failure(ran)))
        } catch {
            answer = .failure(Failure(why: String(describing: error)))
        }
        // Forgotten meanwhile: the machine left (it is read again if it comes back).
        if generation[machineID, default: 0] == started {
            entries[machineID] = switch answer {
            case .success(let state): .known(state)
            case .failure(let failure): .failed(failure.why, at: now(), last: last)
            }
        }
        if case .failure(let failure) = answer { return failure.why }
        return nil
    }

    /// Forgets a machine that left the registry, and drops any read or set still under way for it.
    public func forget(_ machineID: String) {
        generation[machineID, default: 0] += 1
        reading.removeValue(forKey: machineID)?.task.cancel()
        entries[machineID] = nil
    }

    private struct Failure: Error {
        let why: String
    }

    private static func known(_ entry: Entry?) -> CloudVmHost.State? {
        switch entry {
        case .known(let state): state
        case .failed(_, _, let last): last
        default: nil
        }
    }
}
