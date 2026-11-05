public import CmuxNextCompat
public import Foundation
import CmuxNextWakeups
import os

/// Both phone transports share base's sealed file and serial I/O queue. Selection and
/// removal revoke memory trust synchronously; queued transactions are covered by quit's flush.
public final class MobileHostPairedStore: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.pairing")

    public struct Change: Sendable {
        public var list: MobileHostPairedDevices?
        public var removed: [MobileHostPairedDevice]
        /// The account generation the event belongs to (``generation`` when it happened).
        public var generation: UInt64
        /// The event is an account switch or sign-out: `removed` is the earlier account's list.
        public var switchedAccount = false
    }

    private struct Removal: Hashable, Sendable {
        var id: String
        var transport: MobileHostPairedDevice.Transport
    }
    private struct RemovalMarker: Sendable {
        var id: UUID
        /// The store revision at which the removal happened. A transaction that
        /// began before this revision cannot clear the marker, even if its edit
        /// re-adds the removed device.
        var revision: UInt64
    }
    private struct State: Sendable {
        var userID: String?
        var generation: UInt64 = 0
        var revision: UInt64 = 0
        var forgotten: Set<String> = []
        var removals: [Removal: RemovalMarker] = [:]
        var list: MobileHostPairedDevices?
        var file: MobileHostPairedDevicesFile?
        var observers: [@Sendable (Change) -> Void] = []
        /// Reads of this generation's list whose seal the Keychain refused, in a row.
        var refusedReads = 0
        /// The seal stayed unreadable past the waits (``sealWaits``): this generation's list starts empty
        /// and its changes live in memory only, so the stored list and its seal stay as they were and
        /// count again at the next launch whose Keychain answers. A Don't Allow, new keys or a removal is
        /// still written (fail closed), which costs every stored phone one Allow at the next launch.
        var memoryOnly = false
        /// The wait before the next read of a refused seal.
        var sealRetry: Task<Void, Never>?
    }

    private let state = Mutex(State())
    /// Waits between reads of a seal the Keychain refuses (about 30 s in all), then the list starts empty
    /// in memory (``State/memoryOnly``). Until then no phone is trusted and none is asked about.
    public static let sealWaits: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
    private let clock: any Clock<Duration>
    /// The seal of the list in an account folder whose parent is named for the bundle id.
    private let seal: @Sendable (_ bundleID: String) -> any MobileHostPairingSealStore
    /// The app's store: each account folder's list sealed in the Keychain behind the app's one `loginKeychain`.
    public init(loginKeychain: LoginKeychain) {
        seal = { MobileHostKeychainPairingSeal(bundleID: $0, loginKeychain: loginKeychain) }
        clock = ContinuousClock()
    }
    /// A store whose list is sealed by `seal` (tests), waiting on `clock` for a refused seal.
    public init(seal: any MobileHostPairingSealStore, clock: any Clock<Duration> = ContinuousClock()) {
        self.seal = { _ in seal }
        self.clock = clock
    }
    public var current: MobileHostPairedDevices? { state.withLock { $0.list } }
    public var versioned: (list: MobileHostPairedDevices?, revision: UInt64) { state.withLock { ($0.list, $0.revision) } }
    public var generation: UInt64 { state.withLock { $0.generation } }
    public func trusts(_ request: MobileHostPairRequest) -> Bool { current?.decision(for: request) == .trusted }
    public func observe(_ handler: @escaping @Sendable (Change) -> Void) { state.withLock { $0.observers.append(handler) } }

    /// Only the account owner selects. Selecting no account (signed out, or a session that ended by
    /// itself: a refresh token refused, a Keychain that would not hand the tokens back) trusts no phone
    /// and keeps the stored list: the same account signing in again is trusted by the phones it
    /// allowed, as the phone keeps its keys (cmux-next-ios verify/persistence.md). Only the person's
    /// own sign-out forgets them (``forgetForSignOut()``).
    public func select(userID: String?) {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard state.userID != userID else { return nil }
            let removed = state.list?.devices ?? []
            state.userID = userID
            state.generation &+= 1
            state.revision &+= 1
            state.list = nil
            state.removals = [:]
            Self.endSealWait(&state)
            return (Change(list: nil, removed: removed, generation: state.generation, switchedAccount: true), state.observers)
        }
        notify(event)
    }

    /// The person signs out of this Mac (before the session ends): the signed-in account's phones are
    /// forgotten, saved before this returns so a quit cannot miss it, and trusted no more from now on.
    public func forgetForSignOut() {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard let user = state.userID else { return nil }
            if let file = state.file {
                file.saveInBackground(MobileHostPairedDevices(userID: user))
            } else {
                state.forgotten.insert(user)
            }
            let removed = state.list?.devices ?? []
            // A read in flight from before this belongs to an older generation and counts for nothing.
            state.generation &+= 1
            state.revision &+= 1
            state.removals = [:]
            Self.endSealWait(&state)
            // No list until the account is selected again: nothing is trusted, asked about or allowed while
            // the sign-out runs (an Allow then would outlive it).
            state.list = nil
            return (Change(list: nil, removed: removed, generation: state.generation), state.observers)
        }
        notify(event)
    }

    private static func endSealWait(_ state: inout State) {
        state.sealRetry?.cancel()
        state.sealRetry = nil
        state.refusedReads = 0
        state.memoryOnly = false
    }

    public func attach(directory: URL) async {
        configure(directory: directory)
        await reload()
    }

    /// Wire synchronously before selecting the account, so even a same-turn sign-out
    /// queues its seal revocation before the quit's drain of the state files.
    ///
    /// - Parameters:
    ///   - lastQuitCutOff: Whether the last quit's record names the list as cut off (``MobileHostPairedDevicesFile``).
    ///   - cutOffSettled: Told once a cut-off save's fact is safe without that record.
    /// - Returns: The directory's one list file: every read and save of the list, from any transport, runs on its queue.
    @discardableResult
    public func configure(directory: URL, lastQuitCutOff: @escaping @Sendable () -> Bool = { false },
                          cutOffSettled: @escaping @Sendable () -> Void = {}) -> MobileHostPairedDevicesFile {
        state.withLock { state in
            if let file = state.file { return file }
            do {
                let bundleID = directory.deletingLastPathComponent().lastPathComponent
                let file = MobileHostPairedDevicesFile(directory: directory, seal: seal(bundleID),
                                                       lastQuitCutOff: lastQuitCutOff, cutOffSettled: cutOffSettled)
                state.file = file
                for user in state.forgotten { file.saveInBackground(MobileHostPairedDevices(userID: user)) }
                state.forgotten = []
                return file
            }
        }
    }

    public func reload() async {
        await read(retry: false)
    }

    /// Reads the selected account's list. `retry`: the pending wait for a refused seal ended; any other
    /// read while that wait is pending is left to it, so one refusal never starts two chains of waits.
    private func read(retry: Bool) async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                guard let file = state.file, let user = state.userID else {
                    continuation.resume(); return
                }
                if retry { state.sealRetry = nil } else if state.sealRetry != nil {
                    continuation.resume(); return
                }
                let selected = state.generation
                file.enqueue { [self] in
                    guard var list = file.read(userID: user) else {
                        sealRefused(generation: selected, user: user)
                        continuation.resume(); return
                    }
                    // The Keychain answers: the stored list counts again, and saves go to disk. An Allow
                    // given while it refused (memory only) joins the stored list now.
                    let (removals, remembered) = self.state.withLock { state -> ([Removal: RemovalMarker], [MobileHostPairedDevice]) in
                        guard state.generation == selected else { return ([:], []) }
                        defer { state.refusedReads = 0; state.memoryOnly = false }
                        return (state.removals, state.memoryOnly ? state.list?.devices ?? [] : [])
                    }
                    for device in remembered { list.approve(device.request, at: device.pairedAt) }
                    for removal in removals.keys { list.remove(removal.id, transport: removal.transport) }
                    // Even an empty/untrusted load must replace its seal after a removal.
                    if !removals.isEmpty || !remembered.isEmpty {
                        do { try file.save(list) }
                        catch { continuation.resume(); return }
                    }
                    publish(list, generation: selected, completed: removals.mapValues(\.id))
                    continuation.resume()
                }
            }
        }
    }

    /// The Keychain refused the seal of `generation`'s list (on the file's queue): no phone is trusted
    /// and none is asked about while the list is read again after a wait; past ``sealWaits`` the list
    /// starts empty in memory, and the phones are asked about, without touching the stored list.
    private func sealRefused(generation: UInt64, user: String) {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard state.generation == generation, state.userID == user, !state.memoryOnly else { return nil }
            // A list this run already read with its seal stays in force: a later read the Keychain
            // refuses (a same-account update) says nothing new about it.
            guard state.list == nil else { return nil }
            state.sealRetry?.cancel()
            if state.refusedReads < Self.sealWaits.count {
                let wait = Self.sealWaits[state.refusedReads]
                state.refusedReads += 1
                let clock = clock
                // task-owner: stored in `sealRetry`; a new account, a sign-out or the next refusal replaces it
                state.sealRetry = Task { [weak self] in
                    var backoff = Backoff(initial: wait, maximum: wait, jitter: 0)
                    // concurrency-allow: Backoff.wait is an async sleep after a failure (a refused Keychain read), not a blocking wait.
                    do { try await backoff.wait(owner: "iphone-host.pairing-seal", clock: clock) } catch { return }
                    await self?.read(retry: true)
                }
                return nil
            }
            Self.logger.error("iPhone pairing: the Keychain still refuses the pairing seal; phones are asked about again, and this run's answers are kept in memory only")
            state.memoryOnly = true
            state.sealRetry = nil
            var list = MobileHostPairedDevices(userID: user)
            for removal in state.removals.keys { list.remove(removal.id, transport: removal.transport) }
            state.list = list
            state.revision &+= 1
            return (Change(list: list, removed: [], generation: generation), state.observers)
        }
        notify(event)
    }

    /// Whether `next` only allows phones beyond `current` that the stored list (read without its seal,
    /// only to decide this) does not hold with other keys: such an edit may live in memory while the seal
    /// is refused. A Don't Allow, a removal or a phone's new keys is written (fail closed): kept in memory,
    /// the stored list would trust the refused or replaced keys again at the next launch.
    static func onlyAllows(from current: MobileHostPairedDevices, to next: MobileHostPairedDevices,
                           stored: MobileHostPairedDevices?) -> Bool {
        guard next.denied == current.denied else { return false }
        let key = { (device: MobileHostPairedDevice) in "\(device.transport.rawValue)\u{0}\(device.id)" }
        let before = Dictionary(current.devices.map { (key($0), $0) }) { $1 }
        let after = Dictionary(next.devices.map { (key($0), $0) }) { $1 }
        let kept = Dictionary((stored?.devices ?? []).map { (key($0), $0) }) { $1 }
        for (id, device) in before where after[id]?.sameKeys(as: device) != true { return false }
        for (id, device) in after where before[id] == nil {
            if let old = kept[id], !old.sameKeys(as: device) { return false }
        }
        return true
    }

    /// A marker is installed before the read finishes; persistence is queued before this
    /// method returns, and bound to the user who removed the phone, never a later account.
    public func forget(id: String, transport: MobileHostPairedDevice.Transport = .hostd) {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard let user = state.userID else { return nil }
            let removal = Removal(id: id, transport: transport)
            let selected = state.generation
            state.revision &+= 1
            let marker = RemovalMarker(id: UUID(), revision: state.revision)
            state.removals[removal] = marker
            let removed = state.list?.devices.filter { $0.id == id && $0.transport == transport } ?? []
            state.list?.remove(id, transport: transport)
            if let file = state.file {
                file.enqueue { [self] in
                    var list = file.load(userID: user)
                    list.remove(id, transport: transport)
                    do {
                        try file.save(list)
                        publish(list, generation: selected, completed: [removal: marker.id])
                    } catch { /* Memory and the marker stay revoked; a later load retries. */ }
                }
            }
            return (Change(list: state.list, removed: removed, generation: selected), state.observers)
        }
        notify(event)
    }

    public func change(for user: String, generation: UInt64? = nil,
                       _ edit: @escaping @Sendable (inout MobileHostPairedDevices) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            submit(for: user, generation: generation, edit) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Queues `edit` before it returns, so a removal made after this call, even one made before
    /// the edit runs, still wins over it; `done` gets nil once the edit is saved.
    public func submit(for user: String, generation: UInt64? = nil,
                       _ edit: @escaping @Sendable (inout MobileHostPairedDevices) -> Void,
                       done: @escaping @Sendable ((any Error)?) -> Void) {
        state.withLock { state in
            let selected = state.generation
            let startedRevision = state.revision
            guard let file = state.file, state.userID == user, state.list != nil,
                  generation == nil || generation == selected else {
                done(CocoaError(.userCancelled)); return
            }
            file.enqueue { [self] in
                guard let current = self.state.withLock({ state in
                    state.generation == selected ? state.list : nil
                }) else { done(CocoaError(.userCancelled)); return }
                var next = current
                edit(&next)
                do {
                    let completed = self.state.withLock { state -> [Removal: UUID] in
                        guard state.generation == selected, state.userID == user else { return [:] }
                        var completed: [Removal: UUID] = [:]
                        for (removal, marker) in state.removals {
                            // Only an edit that started after the removal may
                            // explicitly approve the same endpoint again.
                            guard startedRevision >= marker.revision else { continue }
                            let before = current.devices.first { $0.id == removal.id && $0.transport == removal.transport }
                            let after = next.devices.first { $0.id == removal.id && $0.transport == removal.transport }
                            if before != after { completed[removal] = marker.id }
                        }
                        return completed
                    }
                    var persisted = next
                    let markers = self.state.withLock { state in
                        state.generation == selected ? state.removals : [:]
                    }
                    for removal in markers.keys where !completed.keys.contains(removal) {
                        persisted.remove(removal.id, transport: removal.transport)
                    }
                    // While the seal is unreadable this run's answers stay in memory (``State/memoryOnly``).
                    let memoryOnly = self.state.withLock { $0.generation == selected && $0.memoryOnly }
                    if !memoryOnly {
                        try file.save(persisted)
                    } else if !Self.onlyAllows(from: current, to: persisted, stored: file.unsealed(userID: user)) {
                        // Written without a seal the Keychain takes: the next launch trusts no stored phone
                        // (fail closed), and this run goes on with the edit.
                        do { try file.save(persisted) } catch MobileHostPairingSealError.keychainRefused {}
                    }
                    publish(persisted, generation: selected, completed: completed)
                    guard self.generation == selected else { throw CocoaError(.userCancelled) }
                    done(nil)
                } catch { done(error) }
            }
        }
    }

    private func publish(_ list: MobileHostPairedDevices, generation: UInt64,
                         completed: [Removal: UUID] = [:]) {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard state.generation == generation, state.userID == list.userID else { return nil }
            for (key, marker) in completed where state.removals[key]?.id == marker { state.removals[key] = nil }
            var next = list
            for removal in state.removals.keys { next.remove(removal.id, transport: removal.transport) }
            let removed = (state.list?.devices ?? []).filter { old in
                !next.devices.contains { $0.id == old.id && $0.transport == old.transport && $0.identityKey == old.identityKey }
            }
            state.list = next
            state.revision &+= 1
            return (Change(list: next, removed: removed, generation: generation), state.observers)
        }
        notify(event)
    }

    private func notify(_ event: (Change, [@Sendable (Change) -> Void])?) {
        if let (change, observers) = event { observers.forEach { $0(change) } }
    }
}
