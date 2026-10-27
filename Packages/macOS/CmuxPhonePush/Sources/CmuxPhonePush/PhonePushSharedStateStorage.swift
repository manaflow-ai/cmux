public import Foundation

/// Storage for push state that the iOS host app writes and its notification
/// service extension reads: the active account and pinned Mac keys.
///
/// The two processes see the same data only through a container both
/// signatures grant. The App Group is absent from the release host App IDs
/// (INTERNAL, BETA, App Store) and from API-key-signed development builds, so
/// an App Group suite silently falls back to a per-process store there and the
/// extension can never decrypt. Every signing lane grants both targets the
/// host's keychain access group, which is what iOS uses.
public protocol PhonePushSharedStateStorage {
    func data(forKey key: String) -> Data?
    /// Stores `data`, or removes the value when `data` is nil.
    func setData(_ data: Data?, forKey key: String)
    func keys(withPrefix prefix: String) -> [String]
}

extension Bundle {
    /// The keychain on iOS, scoped by this bundle's host access group; the
    /// Mac has no extension and keeps its existing process-local defaults.
    public var phonePushSharedStateStorage: any PhonePushSharedStateStorage {
        #if os(iOS)
        PhonePushKeychainStateStorage(
            accessGroup: PhonePushKeychainStateStorage.accessGroup(in: self)
        )
        #else
        PhonePushUserDefaultsStateStorage(defaults: .standard)
        #endif
    }
}

/// Process-local defaults, used by the Mac.
public struct PhonePushUserDefaultsStateStorage: PhonePushSharedStateStorage {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        switch defaults.object(forKey: key) {
        case let data as Data:
            data
        // The peer-key registry was stored as a string array before this
        // storage existed; read it so existing Mac pins keep their order.
        case let strings as [String]:
            try? JSONEncoder().encode(strings)
        default:
            nil
        }
    }

    public func setData(_ data: Data?, forKey key: String) {
        defaults.set(data, forKey: key)
    }

    public func keys(withPrefix prefix: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    }
}
