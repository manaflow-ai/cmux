#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import Foundation
import OSLog
import Security

private let log = Logger(subsystem: "dev.cmux.mobile", category: "classic-leftovers")

/// The one-time cleanup of what the classic iOS app (the same bundle id) left on a
/// phone that updated to this app: its Keychain items and UserDefaults keys.
///
/// Nothing is migrated. The classic Stack session, pairing keys and device ids are
/// not this app's, so the person signs in again from a clean state. Which items go
/// is decided in Rust (`classic_cleanup_plan`, cmux-mobile-link-ffi
/// `classic_leftovers.rs`): only names the classic app is known to write, never
/// this app's own, and anything unknown or malformed is left alone. This type only
/// lists what is there, deletes what the plan names and records that it ran.
///
/// Runs at launch before anything reads the Keychain or settings
/// (`CmuxMobileApp.init`). A Keychain that cannot be read yet (a background launch
/// before the first unlock) plans nothing, and the next launch runs it.
public enum ClassicLeftovers {
    /// What the cleanup reads and deletes.
    public protocol Keychain {
        /// Every generic-password item the app can see; nil when the Keychain
        /// cannot be read yet.
        func items() -> [KeychainLeftover]?
        /// Deletes the items; true when they are gone (deleted, or already missing).
        func delete(service: String, account: String?) -> Bool
    }

    /// The outcome, for the log and tests.
    public struct Outcome: Equatable, Sendable {
        public var ran: Bool
        public var keychainDeleted: Int
        public var defaultsDeleted: Int
        public var kept: Int
        /// Keychain deletes that failed; the cleanup runs again on the next launch.
        public var keychainFailed: Int = 0
    }

    /// Runs the cleanup when it is due.
    @discardableResult
    public static func cleanUpIfDue(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier,
        keychain: any Keychain = SystemKeychain()
    ) -> Outcome {
        let marker = classicCleanupMarkerKey()
        let stored = (defaults.object(forKey: marker) as? NSNumber)?.int64Value
        guard let bundleIdentifier, classicCleanupDue(marker: stored) else {
            return Outcome(ran: false, keychainDeleted: 0, defaultsDeleted: 0, kept: 0, keychainFailed: 0)
        }
        let keys = domain.flatMap { defaults.persistentDomain(forName: $0) }.map { Array($0.keys) } ?? []
        let plan = classicCleanupPlan(bundleId: bundleIdentifier, keychain: keychain.items(), defaultsKeys: keys)
        var failed = 0
        for item in plan.keychainDeletes where !keychain.delete(service: item.service, account: item.account) {
            failed += 1
        }
        for key in plan.defaultsDeletes {
            defaults.removeObject(forKey: key)
        }
        // A failed Keychain delete leaves the marker unset, so the next launch tries again.
        let done = plan.markDone && failed == 0
        if done {
            defaults.set(classicCleanupVersion(), forKey: marker)
        }
        let outcome = Outcome(ran: done, keychainDeleted: plan.keychainDeletes.count - failed,
                              defaultsDeleted: plan.defaultsDeletes.count, kept: Int(plan.kept),
                              keychainFailed: failed)
        log.info("classic leftovers: deleted \(outcome.keychainDeleted) Keychain items, \(outcome.defaultsDeleted) settings; kept \(outcome.kept); failed \(failed); done \(done)")
        return outcome
    }

    /// The app's Keychain: generic passwords in every access group it is signed for.
    public struct SystemKeychain: Keychain {
        public init() {}

        public func items() -> [KeychainLeftover]? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
                log.info("classic leftovers: Keychain not readable (\(status)); trying again next launch")
                return nil
            }
            return rows.map { row in
                KeychainLeftover(service: Self.text(row[kSecAttrService as String]),
                                 account: Self.text(row[kSecAttrAccount as String]))
            }
        }

        public func delete(service: String, account: String?) -> Bool {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service]
            if let account { query[kSecAttrAccount as String] = account }
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                log.info("classic leftovers: Keychain delete failed (\(status)); trying again next launch")
                return false
            }
            return true
        }

        /// An attribute as text: a string, or UTF-8 data; anything else is missing.
        static func text(_ value: Any?) -> String? {
            if let string = value as? String { return string }
            if let data = value as? Data { return String(data: data, encoding: .utf8) }
            return nil
        }
    }
}
#endif
