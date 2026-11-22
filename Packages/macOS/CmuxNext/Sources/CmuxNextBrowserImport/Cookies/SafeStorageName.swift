public import Foundation

/// The name of one Keychain item a browser keeps its storage key in: the
/// service ("Claude Safe Storage", "Helium Storage Key") and its account.
/// Names only: the password is read later, by ``SafeStorageKeyProviding``.
public struct SafeStorageName: Sendable, Hashable {
    public var service: String
    public var account: String?

    public init(service: String, account: String? = nil) {
        self.service = service
        self.account = account
    }
}
