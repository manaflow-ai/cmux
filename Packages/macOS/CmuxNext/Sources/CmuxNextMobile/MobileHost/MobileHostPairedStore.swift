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
    public func forget(userID: String) async { await disk.forget(userID: userID) }
    public func trusts(_ request: MobileHostPairRequest) -> Bool { current?.decision(for: request) == .trusted }
    public func observe(_ handler: @escaping @Sendable (Change) -> Void) { state.withLock { $0.observers.append(handler) } }

    public func change(for user: String, generation: UInt64? = nil,
                       _ edit: @escaping @Sendable (inout MobileHostPairedDevices) -> Void) async throws {
        try await disk.change(store: self, user: user, generation: generation, edit)
    }

    private func publish(_ list: MobileHostPairedDevices, generation: UInt64) {
        let event = state.withLock { state -> (Change, [@Sendable (Change) -> Void])? in
            guard state.generation == generation, state.userID == list.userID else { return nil }
            let removed = (state.list?.devices ?? []).filter { old in
                !list.devices.contains { $0.id == old.id && $0.transport == old.transport && $0.identityKey == old.identityKey }
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
            if file == nil { file = MobileHostPairedDevicesFile(directory: directory) }
            load(store: store)
        }

        func load(store: MobileHostPairedStore) {
            let (user, generation) = store.state.withLock { ($0.userID, $0.generation) }
            guard let user, let file else { return }
            store.publish(file.load(userID: user), generation: generation)
        }

        func forget(userID: String) {
            guard let file, let data = try? Data(blockingContentsOf: file.file),
                  let stored = try? JSONDecoder().decode(MobileHostPairedDevices.self, from: data), stored.userID == userID else { return }
            try? file.save(MobileHostPairedDevices(userID: userID))
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
