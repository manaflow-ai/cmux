import CmuxNextCompat
public import Foundation

/// The one list of phones allowed on this Mac (Settings > Mobile), for both links: hostd's
/// phones (the cmux iOS app) and the Iroh link's (cmux next), as ``MobileHostPairedDevice``
/// entries of their ``MobileHostPairedDevice/Transport`` in one 0600 file per user
/// (`<state>/paired-devices.json`). The iPhone host owns it and hands it to the Iroh host, which
/// checks a connection off the main actor. A change counts only once it is written.
public final class MobileHostPairedStore: Sendable {
    /// A change to the list: the list now (nil: signed out) and the entries it lost.
    public struct Change: Sendable {
        public var list: MobileHostPairedDevices?
        public var removed: [MobileHostPairedDevice]
    }

    private struct State: Sendable {
        var file: MobileHostPairedDevicesFile?
        var userID: String?
        var list: MobileHostPairedDevices?
        var observers: [@Sendable (Change) -> Void] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// The state folder the list lives in; the first one set holds (both links name the same folder).
    public func attach(directory: URL) {
        reload { if $0.file == nil { $0.file = MobileHostPairedDevicesFile(directory: directory) } }
    }

    /// The signed-in user's list; nil (signed out) allows no phone. The same user keeps the list as is.
    /// Only the iPhone host calls this, from its account (``IPhoneHostService/accountChanged(_:)``):
    /// one owner decides whose list it is, and the Iroh link reads it.
    public func load(userID: String?) {
        reload { $0.userID = userID }
    }

    /// The list now; nil while signed out or before ``attach(directory:)``.
    public var current: MobileHostPairedDevices? { state.withLock { $0.list } }

    public func trusts(_ request: MobileHostPairRequest) -> Bool {
        current?.decision(for: request) == .trusted
    }

    public func contains(_ id: String, transport: MobileHostPairedDevice.Transport) -> Bool {
        current?.devices.contains { $0.id == id && $0.transport == transport } ?? false
    }

    /// Edits the list and writes it. Throws, changing nothing, while signed out, when the list is no
    /// longer `user`'s (a question answered after a user switch), or when it cannot be written.
    public func change(for user: String? = nil, _ edit: (inout MobileHostPairedDevices) -> Void) throws {
        let (change, observers) = try state.withLock { state in
            guard let file = state.file, var next = state.list, user.map({ $0 == next.userID }) ?? true else {
                throw CocoaError(.userCancelled)
            }
            let before = next.devices
            edit(&next)
            try file.save(next)
            state.list = next
            // New keys for a listed phone replace its entry; only an entry that is gone counts as removed.
            let removed = before.filter { old in !next.devices.contains { $0.id == old.id && $0.transport == old.transport } }
            return (Change(list: next, removed: removed), state.observers)
        }
        observers.forEach { $0(change) }
    }

    /// Signing out of this Mac forgets `userID`'s phones (and closes the Iroh links of a loaded list).
    public func forget(userID: String) {
        if current?.userID == userID, (try? change({ $0 = MobileHostPairedDevices(userID: userID) })) != nil { return }
        state.withLock { try? $0.file?.save(MobileHostPairedDevices(userID: userID)) }
    }

    /// Calls `handler` after every change, off the lock, on the caller's thread.
    public func observe(_ handler: @escaping @Sendable (Change) -> Void) {
        state.withLock { $0.observers.append(handler) }
    }

    private func reload(_ edit: (inout State) -> Void) {
        let (change, observers): (Change?, [@Sendable (Change) -> Void]) = state.withLock { state in
            edit(&state)
            let next = state.userID.flatMap { user in
                state.list?.userID == user ? state.list : state.file?.load(userID: user)
            }
            guard next != state.list else { return (nil, []) }
            state.list = next
            return (Change(list: next, removed: []), state.observers)
        }
        if let change { observers.forEach { $0(change) } }
    }
}
