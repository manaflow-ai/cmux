import CmuxNextCompat
import CryptoKit
public import Foundation
import LocalAuthentication
import os
import Security

/// Where the digest that seals `paired-devices.json` lives (``MobileHostPairedDevicesFile``). The
/// file says which phone keys this Mac trusts: the identity keys hostd pins and the approval keys
/// acpmux enrolls as approvers (`_acpmux/approvers_set`). Another process of the same user can
/// rewrite a 0600 file, or put back an older copy, so the list counts only when it is exactly the
/// one this app saved last: its digest is kept where such a process cannot write.
public protocol MobileHostPairingSealStore: Sendable {
    /// The digest of the list saved last; nil when there is none or this build may not read it.
    /// Never shows UI.
    func digest() -> Data?
    /// Records `digest` as the list's; false when it cannot be stored.
    func setDigest(_ digest: Data) -> Bool
    /// Forgets the recorded digest, so no copy of any list counts; false when it cannot.
    func clearDigest() -> Bool
}

/// A save the Keychain refused: the new list is on disk, but no list is trusted at the next launch
/// (``MobileHostPairedDevicesFile/save(_:)``).
public enum MobileHostPairingSealError: Error {
    case keychainRefused
}

/// The digest in the data-protection Keychain, in this app's own access group (the signing
/// entitlement's): another process cannot add, change or read an item there, so it can neither
/// plant a digest before first use nor match one to a list of its own. One generic password per
/// bundle id, this device only, never synced. There is no file-keychain fallback: a build without
/// the keychain-access-groups entitlement (an ad hoc signed one) reads no digest, so it keeps no
/// phone across a launch. Reads and writes never show UI (`loadPaired` runs on the main actor).
public struct MobileHostKeychainPairingSeal: MobileHostPairingSealStore {
    public let service: String

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.pairing")

    public init(bundleID: String) {
        service = bundleID + ".iphone-host.pairing-seal"
    }

    /// The item: the data-protection Keychain, the app's default access group, no account sync.
    static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "paired-devices", kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// A context that fails instead of showing UI.
    private static func noPrompt() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private var query: [String: Any] {
        Self.query(service: service).merging([kSecUseAuthenticationContext as String: Self.noPrompt()]) { $1 }
    }

    public func digest() -> Data? {
        var item: CFTypeRef?
        let search = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Self.logger.error("iPhone pairing seal: Keychain read refused (\(status, privacy: .public)); no phone is trusted")
            }
            return nil
        }
        return data
    }

    public func setDigest(_ digest: Data) -> Bool {
        let value = [kSecValueData as String: digest] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, value)
        if status == errSecItemNotFound {
            let add = query.merging([kSecValueData as String: digest, kSecAttrLabel as String: "cmux iPhone pairing seal",
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
            // Another save of this app added it first: write over it.
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, value) }
        }
        guard status == errSecSuccess else {
            Self.logger.error("iPhone pairing seal: Keychain write refused (\(status, privacy: .public)); the list is not trusted after a relaunch")
            return false
        }
        return true
    }

    public func clearDigest() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.logger.error("iPhone pairing seal: Keychain delete refused (\(status, privacy: .public)); the list is not saved")
            return false
        }
        return true
    }
}

/// A seal held in memory: tests, and nothing else. `refuses`: a Keychain that refuses
/// everything; `refuseRecords()`: one that then refuses only a new digest (as a crash between the
/// file and its digest would leave it); `refuseClears()`: one that then keeps the digest it has.
public final class MobileHostMemoryPairingSeal: MobileHostPairingSealStore {
    private struct State {
        var digest: Data?
        var refusesRecords = false
        var refusesClears = false
    }

    private let state = Mutex(State())
    private let refuses: Bool

    public init(refuses: Bool = false) {
        self.refuses = refuses
    }

    public func refuseRecords() {
        state.withLock { $0.refusesRecords = true }
    }

    public func refuseClears() {
        state.withLock { $0.refusesClears = true }
    }

    public func digest() -> Data? {
        refuses ? nil : state.withLock { $0.digest }
    }

    public func setDigest(_ digest: Data) -> Bool {
        guard !refuses else { return false }
        return state.withLock { state in
            guard !state.refusesRecords else { return false }
            state.digest = digest
            return true
        }
    }

    public func clearDigest() -> Bool {
        guard !refuses else { return false }
        return state.withLock { state in
            guard !state.refusesClears else { return false }
            state.digest = nil
            return true
        }
    }
}

enum MobileHostPairingSeal {
    /// The digest of a saved list: SHA-256 over a domain, then the file's exact bytes.
    static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: Data("cmux-paired-devices-seal-v1".utf8) + Data([0]) + data))
    }
}
