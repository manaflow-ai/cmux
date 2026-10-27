import Foundation

/// The generic-password item one Keychain call addresses.
struct KeychainItemAddress: Hashable, Sendable {
    /// The Keychain service. The legacy Stack SDK's items have the empty service.
    let service: String
    let account: String
    /// The exact signed access group, or nil for the app's default group.
    let accessGroup: String?
    /// Whether the query names the data-protection keychain. Current items do; the legacy Stack SDK's
    /// queries left it out.
    let usesDataProtectionKeychain: Bool
}

/// The outcome of one Keychain call.
enum KeychainItemStatus: Equatable, Sendable, CustomStringConvertible {
    case success
    case itemNotFound
    /// Any other outcome, with the Keychain's status code.
    case failed(Int32)

    /// The Keychain status code (`OSStatus`), as the store's diagnostics print it.
    var description: String {
        switch self {
        case .success: "0"
        case .itemNotFound: "-25300"
        case .failed(let code): String(code)
        }
    }
}

/// The Keychain calls ``KeychainStackTokenStore`` makes, so its adoption, hardening and clear rules run
/// against any Keychain: `SecItem` on Apple platforms, none on Linux, an in-memory one in tests.
protocol KeychainItemStoring: Sendable {
    /// The item's data.
    func copyData(_ item: KeychainItemAddress) -> (status: KeychainItemStatus, data: Data?)
    /// Makes the item accessible after first unlock on this device only, and replaces its data when
    /// `data` is non-nil.
    func update(_ item: KeychainItemAddress, data: Data?) -> KeychainItemStatus
    /// Adds the item with `data`, accessible after first unlock on this device only.
    func add(_ item: KeychainItemAddress, data: Data) -> KeychainItemStatus
    func delete(_ item: KeychainItemAddress) -> KeychainItemStatus
}

/// The Keychain where none exists (Linux): it holds no item and refuses every add, so
/// ``FallbackTokenStore`` routes writes to its file store.
struct UnavailableKeychain: KeychainItemStoring {
    /// `errSecNotAvailable`.
    static let notAvailable = KeychainItemStatus.failed(-25291)

    func copyData(_ item: KeychainItemAddress) -> (status: KeychainItemStatus, data: Data?) {
        (.itemNotFound, nil)
    }

    func update(_ item: KeychainItemAddress, data: Data?) -> KeychainItemStatus {
        .itemNotFound
    }

    func add(_ item: KeychainItemAddress, data: Data) -> KeychainItemStatus {
        Self.notAvailable
    }

    func delete(_ item: KeychainItemAddress) -> KeychainItemStatus {
        .itemNotFound
    }
}
