public import Foundation
import Synchronization

/// A write to a key an MDM profile or the team policy manages.
public nonisolated struct SettingManaged: Error, Sendable, CustomStringConvertible, Equatable {
    public let key: String
    public let source: ManagedSource

    public var description: String {
        switch source {
        case .device: "\(key) is managed by your organization"
        case .team(let name): "\(key) is managed by \(name.isEmpty ? "your team" : name)"
        }
    }
}

/// The managed keys of the last settings load. `CmuxConfigFile` checks it on
/// every write, so the Settings window, palette actions and the control
/// socket's `settings.set` all refuse a managed key through one check.
public final nonisolated class ManagedKeyGuard: Sendable {
    private let state = Mutex<[[String]: (key: String, source: ManagedSource)]>([:])

    public init() {}

    /// Replaces the managed set (called by `SettingsController` after each load).
    public func update(_ managed: [String: ManagedSource]) {
        let byPath = Dictionary(managed.map { (CmuxConfigFile.keyPath(from: $0.key), (key: $0.key, source: $0.value)) }, uniquingKeysWith: { first, _ in first })
        state.withLock { $0 = byPath }
    }

    public var managedKeys: [String: ManagedSource] {
        state.withLock { Dictionary($0.values.map { ($0.key, $0.source) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// Throws when setting `value` at `path` would change a managed key:
    /// the path is a managed key or inside one, or `value` (an object at an
    /// ancestor) contains a managed key.
    public func checkSet(_ value: JSONValue?, at path: [String]) throws {
        try state.withLock { managed in
            for (managedPath, entry) in managed {
                if path.starts(with: managedPath) { throw SettingManaged(key: entry.key, source: entry.source) }
                if managedPath.starts(with: path), let value, value.value(at: Array(managedPath.dropFirst(path.count))) != nil {
                    throw SettingManaged(key: entry.key, source: entry.source)
                }
            }
        }
    }

    /// Throws when removing `path` removes a managed key's own value. Removing
    /// an ancestor object is allowed (it only prunes the user's file; the
    /// managed value still applies from its layer).
    public func checkRemove(_ path: [String]) throws {
        try state.withLock { managed in
            for (managedPath, entry) in managed where path.starts(with: managedPath) {
                throw SettingManaged(key: entry.key, source: entry.source)
            }
        }
    }
}
