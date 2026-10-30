import CmuxNextCompat
public import Foundation

/// One owner selects the signed-in user; both phone transports share this list.
/// Disk work is serialized off the main actor. A failed save publishes no trust.
public final class MobileHostPairedStore: Sendable {
    public struct Change: Sendable {
        public var list: MobileHostPairedDevices?
        public var removed: [MobileHostPairedDevice]
    }

    private struct State: Sendable {
        var userID: String?
        var generation: UInt64 = 0
        var revision: UInt64 = 0
        var forgotten: Set<String> = []
        var pendingRemovals: Set<String> = []
        var list: MobileHostPairedDevices?
        var observers: [@Sendable (Change) -> Void] = []
    }

    private let state = Mutex(State())
    private let disk = Persistence()
    public init() {}
    public var current: MobileHostPairedDevices? { state.withLock { $0.list } }
    public var versioned: (list: MobileHostPairedDevices?, revision: UInt64) { state.withLock { ($0.list, $0.revision) } }
    public var generation: UInt64 { state.withLock { $0.generation } }

    /// Only IPhoneHostService selects the user. Invalidate synchronously before any await,
    /// including a switch away and back while a question is open.
    public func select(userID: String?) {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard state.userID != userID else { return nil }
            let removed = state.list?.devices ?? []
            if userID == nil, let previous = state.userID { state.forgotten.insert(previous) }
            state.userID = userID
            state.generation &+= 1
            state.revision &+= 1
            state.list = nil
            return (Change(list: nil, removed: removed), state.observers)
        }
        if let (change, observers) = event { observers.forEach { $0(change) } }
    }

    public func attach(directory: URL) async { await disk.attach(directory: directory, store: self) }
    public func reload() async { await disk.load(store: self) }
    public func trusts(_ request: MobileHostPairRequest) -> Bool { current?.decision(for: request) == .trusted }
    public func observe(_ handler: @escaping @Sendable (Change) -> Void) { state.withLock { $0.observers.append(handler) } }

    public func change(for user: String, generation: UInt64? = nil,
                       _ edit: @escaping @Sendable (inout MobileHostPairedDevices) -> Void) async throws {
        try await disk.change(store: self, user: user, generation: generation, edit)
    }

    /// Forget a phone even when its initial disk load is still in flight. The marker is
    /// synchronous, so a load that finishes after this call cannot re-trust the phone.
    public func forget(id: String, transport: MobileHostPairedDevice.Transport = .hostd) {
        let key = Self.removalKey(id, transport)
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard state.userID != nil else { return nil }
            state.pendingRemovals.insert(key)
            guard let list = state.list else { return nil }
            var next = list
            next.remove(id, transport: transport)
            guard next != list else { return nil }
            let removed = list.devices.filter { $0.id == id && $0.transport == transport }
            state.list = next
            state.revision &+= 1
            return (Change(list: next, removed: removed), state.observers)
        }
        if let (change, observers) = event { observers.forEach { $0(change) } }
        Task { await disk.forget(store: self, id: id, transport: transport, key: key) }
    }

    private static func removalKey(_ id: String, _ transport: MobileHostPairedDevice.Transport) -> String {
        transport.rawValue + "\u{0}" + id
    }

    private func publish(_ list: MobileHostPairedDevices, generation: UInt64) {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard state.generation == generation, state.userID == list.userID else { return nil }
            let removed = (state.list?.devices ?? []).filter { old in
                !list.devices.contains { $0.id == old.id && $0.transport == old.transport && $0.identityKey == old.identityKey }
            }
            var list = list
            for key in state.pendingRemovals {
                let parts = key.split(separator: "\0", maxSplits: 1).map(String.init)
                if parts.count == 2, let transport = MobileHostPairedDevice.Transport(rawValue: parts[0]) {
                    list.remove(parts[1], transport: transport)
                }
            }
            state.list = list
            state.revision &+= 1
            return (Change(list: list, removed: removed), state.observers)
        }
        if let (change, observers) = event { observers.forEach { $0(change) } }
    }

    private actor Persistence {
        var file: MobileHostPairedDevicesFile?
        func attach(directory: URL, store: MobileHostPairedStore) {
            if file == nil {
                let bundleID = directory.deletingLastPathComponent().lastPathComponent
                file = MobileHostPairedDevicesFile(directory: directory,
                                                   seal: MobileHostKeychainPairingSeal(bundleID: bundleID))
            }
            load(store: store)
        }

        func load(store: MobileHostPairedStore) {
            let (user, generation, forgotten) = store.state.withLock { ($0.userID, $0.generation, $0.forgotten) }
            guard let file else { return }
            // Every later load flushes sign-out first, even if sign-in raced its owner task.
            for revoked in forgotten {
                let old = file.load(userID: revoked)
                do {
                    if !old.devices.isEmpty || !old.denied.isEmpty { try file.save(MobileHostPairedDevices(userID: revoked)) }
                    _ = store.state.withLock { $0.forgotten.remove(revoked) }
                } catch { return }
            }
            guard let user else { return }
            store.publish(file.load(userID: user), generation: generation)
        }

        func forget(store: MobileHostPairedStore, id: String, transport: MobileHostPairedDevice.Transport, key: String) {
            let (user, generation, pending) = store.state.withLock { ($0.userID, $0.generation, $0.pendingRemovals) }
            guard let user, let file else { return }
            var list = file.load(userID: user)
            list.remove(id, transport: transport)
            do {
                try file.save(list)
                store.state.withLock { state in
                    guard state.userID == user, state.generation == generation else { return }
                    state.pendingRemovals.subtract(pending.intersection([key]))
                }
            } catch { }
        }

        func change(store: MobileHostPairedStore, user: String, generation: UInt64?,
                    _ edit: @Sendable (inout MobileHostPairedDevices) -> Void) throws {
            let (current, selected) = store.state.withLock { ($0.list, $0.generation) }
            guard let file, var next = current, next.userID == user, generation == nil || generation == selected else {
                throw CocoaError(.userCancelled)
            }
            edit(&next)
            try file.save(next)
            // Selection may have changed during the write; that answer grants nothing.
            guard store.generation == selected else { throw CocoaError(.userCancelled) }
            store.publish(next, generation: selected)
        }
    }
}
