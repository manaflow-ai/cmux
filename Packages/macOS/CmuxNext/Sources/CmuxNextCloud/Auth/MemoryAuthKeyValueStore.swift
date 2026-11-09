import CMUXAuthCore
import Foundation
import CmuxNextCompat

/// The auth caches of a launch whose session lives in memory only (``CloudAuth/LaunchSignIn/memoryOnly``):
/// its cached user, team and has-tokens flag end with the process and never reach the app's defaults.
final class MemoryAuthKeyValueStore: CMUXAuthKeyValueStore, Sendable {
    private enum Value: Sendable { case flag(Bool), data(Data), text(String) }
    private let values = Mutex<[String: Value]>([:])

    func bool(forKey defaultName: String) -> Bool {
        values.withLock { if case .flag(let value) = $0[defaultName] { return value }; return false }
    }
    func data(forKey defaultName: String) -> Data? {
        values.withLock { if case .data(let value) = $0[defaultName] { return value }; return nil }
    }
    func string(forKey defaultName: String) -> String? {
        values.withLock { if case .text(let value) = $0[defaultName] { return value }; return nil }
    }
    func set(_ value: Any?, forKey defaultName: String) {
        let stored: Value?
        switch value {
        case let flag as Bool: stored = .flag(flag)
        case let data as Data: stored = .data(data)
        case let text as String: stored = .text(text)
        default: stored = nil
        }
        values.withLock { $0[defaultName] = stored }
    }
    func removeObject(forKey defaultName: String) {
        _ = values.withLock { $0.removeValue(forKey: defaultName) }
    }
}
