public import CmuxNextCompat
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
/// bundle id, this device only, never synced. Reads and writes never show UI (`loadPaired` runs on
/// the main actor).
///
/// A build signed without the keychain-access-groups entitlement (cmux NEXT nightly, which embeds
/// no provisioning profile, and ad hoc tagged builds) gets `errSecMissingEntitlement` from the
/// data-protection Keychain; it keeps the digest in the login Keychain instead, as the Mac's identity
/// key (``MobileHostMacIdentityStore``) and the relay secrets already do, so one Allow holds across
/// relaunches and updates (https://github.com/manaflow-ai/cmux/issues/26396). Only that answer
/// moves a call there: an entitled build never reads the login Keychain, so an item planted there
/// counts for nothing in it, and an item left there from before the entitlement is never moved over.
/// In a build without the entitlement the seal is weaker: it catches a rewritten file, but a
/// same-user process can delete the item or plant its own (no item is the app's alone there). Such
/// a build has no store a same-user process cannot write; signing it with a profile that grants
/// keychain-access-groups puts the seal back in the app's access group. A login item this build may
/// not read or change (a locked keychain, an ad hoc rebuild) fails without UI (Keychain interaction
/// is off for those calls): the phone asks again.
public struct MobileHostKeychainPairingSeal: MobileHostPairingSealStore {
    public let service: String
    let keychain: MobileHostSecItems
    /// The app's one guard of the Keychain UI switch (the login Keychain fallback).
    let loginKeychain: LoginKeychain

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.pairing")

    public init(bundleID: String, loginKeychain: LoginKeychain) {
        self.init(bundleID: bundleID, keychain: .system, loginKeychain: loginKeychain)
    }

    init(bundleID: String, keychain: MobileHostSecItems, loginKeychain: LoginKeychain) {
        service = bundleID + ".iphone-host.pairing-seal"
        self.keychain = keychain
        self.loginKeychain = loginKeychain
    }

    /// The item: the data-protection Keychain, the app's default access group, no account sync.
    static func query(service: String) -> [String: Any] {
        loginQuery(service: service).merging([kSecUseDataProtectionKeychain as String: true]) { $1 }
    }

    /// The same item in the login Keychain, for a build without the entitlement.
    static func loginQuery(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "paired-devices", kSecAttrSynchronizable as String: false]
    }

    /// A context that fails instead of showing UI.
    private static func noPrompt() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// Runs `call` against the data-protection Keychain, and again against the login Keychain when
    /// this build has no entitlement for the first. The login call runs with Keychain UI off
    /// (``LoginKeychain/withoutUI(_:)``): the `LAContext` does not reach the login Keychain, and an
    /// item an earlier build of this bundle id made under another signature would otherwise prompt
    /// for the login keychain password.
    private func perform<T>(_ call: ([String: Any]) -> (status: OSStatus, value: T)) -> (status: OSStatus, value: T) {
        let noPrompt = [kSecUseAuthenticationContext as String: Self.noPrompt()]
        let result = call(Self.query(service: service).merging(noPrompt) { $1 })
        guard result.status == errSecMissingEntitlement else { return result }
        return loginKeychain.withoutUI { call(Self.loginQuery(service: service).merging(noPrompt) { $1 }) }
    }

    public func digest() -> Data? {
        let (status, data) = perform { query in
            keychain.copy(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 })
        }
        guard status == errSecSuccess, let data else {
            if status != errSecItemNotFound {
                Self.logger.error("iPhone pairing seal: Keychain read refused (\(status, privacy: .public)); no phone is trusted")
            }
            return nil
        }
        return data
    }

    public func setDigest(_ digest: Data) -> Bool {
        let (status, _) = perform { query in
            let value = [kSecValueData as String: digest]
            var status = keychain.update(query, value)
            if status == errSecItemNotFound {
                let add = query.merging([kSecValueData as String: digest, kSecAttrLabel as String: "cmux iPhone pairing seal",
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
                status = keychain.add(add)
                // Another save of this app added it first: write over it.
                if status == errSecDuplicateItem { status = keychain.update(query, value) }
            }
            return (status, ())
        }
        guard status == errSecSuccess else {
            Self.logger.error("iPhone pairing seal: Keychain write refused (\(status, privacy: .public)); the list is not trusted after a relaunch")
            return false
        }
        return true
    }

    public func clearDigest() -> Bool {
        let (status, _) = perform { query in (keychain.delete(query), ()) }
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
