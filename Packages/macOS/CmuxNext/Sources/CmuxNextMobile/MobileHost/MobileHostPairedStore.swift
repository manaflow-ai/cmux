import CmuxNextCompat
public import Foundation

/// Both phone transports share base's sealed file and serial I/O queue. Selection and
/// removal revoke memory trust synchronously; queued transactions are covered by quit's flush.
public final class MobileHostPairedStore: Sendable {
    public struct Change: Sendable {
        public var list: MobileHostPairedDevices?
        public var removed: [MobileHostPairedDevice]
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
    }

    private let state = Mutex(State())
    private let seal: (any MobileHostPairingSealStore)?
    public init(seal: (any MobileHostPairingSealStore)? = nil) { self.seal = seal }
    public var current: MobileHostPairedDevices? { state.withLock { $0.list } }
    public var versioned: (list: MobileHostPairedDevices?, revision: UInt64) { state.withLock { ($0.list, $0.revision) } }
    public var generation: UInt64 { state.withLock { $0.generation } }
    public func trusts(_ request: MobileHostPairRequest) -> Bool { current?.decision(for: request) == .trusted }
    public func observe(_ handler: @escaping @Sendable (Change) -> Void) { state.withLock { $0.observers.append(handler) } }

    /// Only the account owner selects. Enqueue sign-out before returning, so a quit cannot
    /// miss it, even when another sign-in overtakes the pending read.
    public func select(userID: String?) {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard state.userID != userID else { return nil }
            let removed = state.list?.devices ?? []
            if userID == nil, let previous = state.userID {
                if let file = state.file {
                    file.saveInBackground(MobileHostPairedDevices(userID: previous))
                } else {
                    state.forgotten.insert(previous)
                }
            }
            state.userID = userID
            state.generation &+= 1
            state.revision &+= 1
            state.list = nil
            state.removals = [:]
            return (Change(list: nil, removed: removed), state.observers)
        }
        notify(event)
    }

    public func attach(directory: URL) async {
        configure(directory: directory)
        await reload()
    }

    /// Wire synchronously before selecting the account, so even a same-turn sign-out
    /// queues its seal revocation before the application termination flush.
    public func configure(directory: URL) {
        state.withLock { state in
            if state.file == nil {
                let bundleID = directory.deletingLastPathComponent().lastPathComponent
                let file = MobileHostPairedDevicesFile(directory: directory,
                    seal: seal ?? MobileHostKeychainPairingSeal(bundleID: bundleID))
                state.file = file
                for user in state.forgotten { file.saveInBackground(MobileHostPairedDevices(userID: user)) }
                state.forgotten = []
            }
        }
    }

    public func reload() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                guard let file = state.file, let user = state.userID else {
                    continuation.resume(); return
                }
                let selected = state.generation
                MobileHostPairedDevicesFile.enqueue { [self] in
                    var list = file.load(userID: user)
                    let removals = self.state.withLock { state in
                        state.generation == selected ? state.removals : [:]
                    }
                    for removal in removals.keys { list.remove(removal.id, transport: removal.transport) }
                    // Even an empty/untrusted load must replace its seal after a removal.
                    if !removals.isEmpty {
                        do { try file.save(list) }
                        catch { continuation.resume(); return }
                    }
                    publish(list, generation: selected, completed: removals.mapValues(\.id))
                    continuation.resume()
                }
            }
        }
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
                MobileHostPairedDevicesFile.enqueue { [self] in
                    var list = file.load(userID: user)
                    list.remove(id, transport: transport)
                    do {
                        try file.save(list)
                        publish(list, generation: selected, completed: [removal: marker.id])
                    } catch { /* Memory and the marker stay revoked; a later load retries. */ }
                }
            }
            return (Change(list: state.list, removed: removed), state.observers)
        }
        notify(event)
    }

    public func change(for user: String, generation: UInt64? = nil,
                       _ edit: @escaping @Sendable (inout MobileHostPairedDevices) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.withLock { state in
                let selected = state.generation
                let startedRevision = state.revision
                guard let file = state.file, state.userID == user, state.list != nil,
                      generation == nil || generation == selected else {
                    continuation.resume(throwing: CocoaError(.userCancelled)); return
                }
                MobileHostPairedDevicesFile.enqueue { [self] in
                    guard let current = self.state.withLock({ state in
                        state.generation == selected ? state.list : nil
                    }) else { continuation.resume(throwing: CocoaError(.userCancelled)); return }
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
                        try file.save(persisted)
                        publish(persisted, generation: selected, completed: completed)
                        guard self.generation == selected else { throw CocoaError(.userCancelled) }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
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
            return (Change(list: next, removed: removed), state.observers)
        }
        notify(event)
    }

    private func notify(_ event: (Change, [@Sendable (Change) -> Void])?) {
        if let (change, observers) = event { observers.forEach { $0(change) } }
    }
}
