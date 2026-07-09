import Foundation

// Safety: this wrapper stores an immutable UserDefaults reference and exposes
// only individual per-key reads and writes, which UserDefaults supports across
// app threads.
final class MobileTelemetryConsentDefaultsBacking: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
