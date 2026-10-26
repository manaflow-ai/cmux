import Foundation

/// `UserDefaults` installation marker storage for production composition.
///
/// It keeps the domain's name, not a `UserDefaults` object (which is not `Sendable`), and opens the
/// domain on each call; every `UserDefaults` for one suite reads and writes the same process-wide
/// preferences.
public final class CmxIrohUserDefaultsInstallStateStore: CmxIrohInstallStateStoring {
    private enum Domain: Sendable {
        case standard
        case suite(String)
    }

    private let domain: Domain

    /// Creates a state store over the app's standard defaults.
    public init() {
        domain = .standard
    }

    /// Creates a state store over one defaults suite.
    ///
    /// - Parameter suiteName: The suite's name. Returns nil for a name `UserDefaults(suiteName:)`
    ///   refuses (the app's bundle identifier or `NSGlobalDomain`).
    public init?(suiteName: String) {
        guard UserDefaults(suiteName: suiteName) != nil else { return nil }
        domain = .suite(suiteName)
    }

    public func string(forKey key: String) -> String? {
        defaults?.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        guard let defaults else { return }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private var defaults: UserDefaults? {
        switch domain {
        case .standard:
            .standard
        case let .suite(name):
            UserDefaults(suiteName: name)
        }
    }
}
