import Foundation

/// The key-value persistence seam the auth caches write through.
///
/// Production injects `UserDefaults`; tests inject an in-memory conformer so
/// no test touches the developer's real defaults. Only the operations the
/// auth caches actually need are required.
public protocol CMUXAuthKeyValueStore: AnyObject {
    /// The boolean stored under `defaultName` (`false` when absent).
    func bool(forKey defaultName: String) -> Bool
    /// The data blob stored under `defaultName`, if any.
    func data(forKey defaultName: String) -> Data?
    /// The string stored under `defaultName`, if any.
    func string(forKey defaultName: String) -> String?
    /// Store `value` under `defaultName`.
    func set(_ value: Any?, forKey defaultName: String)
    /// Remove any value stored under `defaultName`.
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: CMUXAuthKeyValueStore {}
