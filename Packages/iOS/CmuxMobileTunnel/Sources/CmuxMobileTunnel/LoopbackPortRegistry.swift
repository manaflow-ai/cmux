import Foundation

/// Who owns each port on the phone's loopback among the app's tunnel
/// listeners, across every computer (SSH hosts and paired Macs).
///
/// The phone has one loopback. When two computers both serve `:3000`, the
/// page being opened now wants its own computer's, so a mirror evicts another
/// owner's forward on the same port instead of silently reaching the wrong
/// machine. Proxies register as pinned: a mirror never takes their port.
@MainActor
public final class LoopbackPortRegistry {
    public static let shared = LoopbackPortRegistry()

    public struct Entry {
        public let owner: String
        /// Pinned entries (proxy listeners) are never evicted by a mirror.
        public let pinned: Bool
        let stop: @MainActor () async -> Void
    }

    private var entries: [Int: Entry] = [:]

    public init() {}

    public func entry(for port: Int) -> Entry? {
        entries[port]
    }

    /// Ports held by pinned listeners (proxies) of any owner.
    public var pinnedPorts: Set<Int> {
        Set(entries.filter(\.value.pinned).keys)
    }

    public func ports(ownedBy owner: String) -> Set<Int> {
        Set(entries.filter { $0.value.owner == owner }.keys)
    }

    /// Records a listener the caller just bound. `stop` runs if another
    /// owner evicts it.
    public func register(port: Int, owner: String, pinned: Bool = false, stop: @escaping @MainActor () async -> Void) {
        entries[port] = Entry(owner: owner, pinned: pinned, stop: stop)
    }

    /// Forgets a listener its owner stopped itself.
    public func release(port: Int, owner: String) {
        guard entries[port]?.owner == owner else { return }
        entries[port] = nil
    }

    /// Stops and forgets another owner's unpinned listener on `port`, so the
    /// caller can bind it. Returns false when the port is pinned.
    @discardableResult
    public func evict(port: Int, for owner: String) async -> Bool {
        guard let entry = entries[port] else { return true }
        guard entry.owner != owner else { return true }
        guard !entry.pinned else { return false }
        entries[port] = nil
        await entry.stop()
        return true
    }
}
