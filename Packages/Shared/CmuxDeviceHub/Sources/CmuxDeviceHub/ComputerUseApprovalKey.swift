public import CryptoKit
public import Foundation
import LocalAuthentication
public import Security

/// The private half of an approver's **approval key** (docs/computer-use-approvals.md,
/// "Device hub approvals"): it signs a Computer Use Allow (`once`, `session`, `always`)
/// and nothing else. On a real device it is a Secure Enclave key whose access control
/// is ``ComputerUseApprovalKey/accessControlFlags``, so the OS itself asks for Face ID
/// (or the passcode) before every signature; code in the app cannot sign an Allow
/// without the person. The device's signing key never signs an Allow.
public protocol ComputerUseApprovalKeyMaterial: Sendable {
    var publicKey: P256.Signing.PublicKey { get }
    /// What the Keychain keeps: the enclave's encrypted blob (a simulator's raw key).
    var stored: Data { get }
    /// ECDSA-P256-SHA256 over `message`, under the presence check `presence` passed.
    func signature(for message: Data, presence: ComputerUseApprovalPresence) throws -> P256.Signing.ECDSASignature
}

/// One passed Face ID or passcode check: the evaluated `LAContext`, so the enclave
/// key signs under it and the person sees one prompt. Nil context: the key asks itself.
/// It is good for one signature: the first use takes it and invalidates the context.
public final class ComputerUseApprovalPresence: @unchecked Sendable { // crash-allow: `context` is immutable; `used` is behind its Mutex
    let context: LAContext?
    private let used = Mutex(false)

    init(context: LAContext?) {
        self.context = context
    }

    /// Takes this check for one signature; false when it was already used.
    func take() -> Bool {
        used.withLock { used in
            defer { used = true }
            return !used
        }
    }

    /// After the one signature: the enclave refuses the context from now on.
    func spend() {
        context?.invalidate()
    }

    /// No evaluated context (tests; an enclave key then prompts on its own).
    public static func unchecked() -> ComputerUseApprovalPresence { ComputerUseApprovalPresence(context: nil) }
}

/// How approval keys are made, read back and unlocked. The app uses ``platform``;
/// tests inject software keys and record what access control a key was made with.
public struct ComputerUseApprovalKeyFactory: Sendable {
    /// Makes a new key whose every use needs `flags` (always
    /// ``ComputerUseApprovalKey/accessControlFlags``), kept under `protection`
    /// (a `kSecAttrAccessible…` value).
    public var make: @Sendable (_ flags: SecAccessControlCreateFlags, _ protection: String) throws -> any ComputerUseApprovalKeyMaterial
    /// The key from what the Keychain kept; nil when it is not one (another enclave, a damaged item).
    public var restore: @Sendable (Data) -> (any ComputerUseApprovalKeyMaterial)?
    /// Asks the person for Face ID, or the passcode; throws when they cancel or fail.
    public var checkPresence: @Sendable (_ reason: String) async throws -> ComputerUseApprovalPresence

    public init(make: @escaping @Sendable (SecAccessControlCreateFlags, String) throws -> any ComputerUseApprovalKeyMaterial,
                restore: @escaping @Sendable (Data) -> (any ComputerUseApprovalKeyMaterial)?,
                checkPresence: @escaping @Sendable (String) async throws -> ComputerUseApprovalPresence) {
        self.make = make
        self.restore = restore
        self.checkPresence = checkPresence
    }

    /// The Secure Enclave: the key's access control asks for the person on every signature.
    public static let enclave = ComputerUseApprovalKeyFactory(
        make: { flags, protection in
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, protection as CFString, flags, &error) else {
                throw DeviceIdentity.Failure.keychain(errSecParam)
            }
            return EnclaveApprovalKey(key: try SecureEnclave.P256.Signing.PrivateKey(accessControl: access))
        },
        restore: { blob in (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)).map(EnclaveApprovalKey.init) },
        checkPresence: ComputerUseApprovalKeyFactory.deviceOwnerAuthentication
    )

    /// The iOS simulator only (no Secure Enclave): a software key in the Keychain, behind
    /// the same Face ID check the app asks for (`xcrun simctl` can match it). A device
    /// build never uses it (``platform``).
    static let simulatorSoftware = ComputerUseApprovalKeyFactory(
        make: { _, _ in SoftwareApprovalKey(key: P256.Signing.PrivateKey()) },
        restore: { raw in (try? P256.Signing.PrivateKey(rawRepresentation: raw)).map(SoftwareApprovalKey.init) },
        checkPresence: ComputerUseApprovalKeyFactory.deviceOwnerAuthentication
    )

    /// What this build uses: the Secure Enclave, except in the simulator, which has none
    /// (it refuses to make an enclave key with user presence).
    public static var platform: ComputerUseApprovalKeyFactory {
        #if targetEnvironment(simulator)
        simulatorSoftware
        #else
        enclave
        #endif
    }

    /// Face ID, or the passcode when Face ID fails or is not set up.
    static let deviceOwnerAuthentication: @Sendable (String) async throws -> ComputerUseApprovalPresence = { reason in
        let context = LAContext()
        context.localizedFallbackTitle = nil
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        return ComputerUseApprovalPresence(context: context)
    }
}

/// An approver's approval key: its public half is registered on the device hub as the
/// device's `approvalKey` and pinned by the boxes that take this device's answers
/// (by ``fingerprint``); its private half signs Allows only after Face ID.
public struct ComputerUseApprovalKey: Sendable {
    /// User presence on every use, inside the Secure Enclave (as the phone's Mac approval key).
    public static let accessControlFlags: SecAccessControlCreateFlags = [.privateKeyUsage, .userPresence]
    /// Usable only while the device is unlocked, never moved to another device.
    public static let protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    public enum Failure: Error, Equatable, Sendable {
        /// One Face ID check signs one Allow: this authorization already signed.
        case authorizationUsed
    }

    let material: any ComputerUseApprovalKeyMaterial
    let factory: ComputerUseApprovalKeyFactory

    init(material: any ComputerUseApprovalKeyMaterial, factory: ComputerUseApprovalKeyFactory) {
        self.material = material
        self.factory = factory
    }

    /// A new key from `factory`, made with ``accessControlFlags`` and not kept (tests).
    public init(making factory: ComputerUseApprovalKeyFactory) throws {
        self.init(material: try factory.make(Self.accessControlFlags, Self.protection), factory: factory)
    }

    /// base64 of the public key's 65 X9.63 bytes: the device's `approvalKey`.
    public var publicKey: String { material.publicKey.x963Representation.base64EncodedString() }
    /// The lowercase hex SHA-256 of those 65 bytes: what a box pins.
    public var fingerprint: String { DeviceIdentity.fingerprint(signingKeyX963: material.publicKey.x963Representation) }

    /// Asks for Face ID (or the passcode) with `reason` on the system sheet, then
    /// returns what signs one Allow under that check.
    public func authorize(reason: String) async throws -> ComputerUseApprovalAuthorization {
        let presence = try await factory.checkPresence(reason)
        return ComputerUseApprovalAuthorization(material: material, presence: presence)
    }

    /// The key kept under `account`, made when there is none. Throws
    /// ``DeviceIdentity/Failure/corruptKeyBlob`` when a kept key cannot be read back:
    /// the hub keeps a device's first approval key, so that device is replaced.
    static func load(keychain: DeviceKeychain, account: String, factory: ComputerUseApprovalKeyFactory) throws -> ComputerUseApprovalKey {
        if let blob = try keychain.read(account) {
            guard let material = factory.restore(blob) else { throw DeviceIdentity.Failure.corruptKeyBlob }
            return ComputerUseApprovalKey(material: material, factory: factory)
        }
        let key = try ComputerUseApprovalKey(making: factory)
        try keychain.add(key.material.stored, account: account)
        return key
    }
}

/// One Allow's signer: the approval key under a passed presence check.
public struct ComputerUseApprovalAuthorization: Sendable {
    let material: any ComputerUseApprovalKeyMaterial
    let presence: ComputerUseApprovalPresence

    /// base64 X9.63 of the approval key that signs.
    public var publicKey: String { material.publicKey.x963Representation.base64EncodedString() }

    /// base64 raw r||s over `"cmux-cu-approval-v1\n<digest>\n<decision>"` (the message is the same for every key).
    /// One signature per authorization: a second call throws ``ComputerUseApprovalKey/Failure/authorizationUsed``.
    public func signApproval(digest: String, decision: ComputerUseDecision) throws -> String {
        guard presence.take() else { throw ComputerUseApprovalKey.Failure.authorizationUsed }
        defer { presence.spend() }
        return try material.signature(for: Data(decision.signatureMessage(digest: digest).utf8), presence: presence)
            .rawRepresentation.base64EncodedString()
    }
}

/// A Secure Enclave approval key. Bound to the evaluated context when there is one,
/// so the person sees one prompt; the enclave refuses a context that did not pass.
struct EnclaveApprovalKey: ComputerUseApprovalKeyMaterial {
    let key: SecureEnclave.P256.Signing.PrivateKey

    var publicKey: P256.Signing.PublicKey { key.publicKey }
    var stored: Data { key.dataRepresentation }

    func signature(for message: Data, presence: ComputerUseApprovalPresence) throws -> P256.Signing.ECDSASignature {
        guard let context = presence.context else { return try key.signature(for: message) }
        let bound = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: key.dataRepresentation, authenticationContext: context)
        return try bound.signature(for: message)
    }
}

/// A software approval key: the simulator, and tests.
struct SoftwareApprovalKey: ComputerUseApprovalKeyMaterial {
    let key: P256.Signing.PrivateKey

    var publicKey: P256.Signing.PublicKey { key.publicKey }
    var stored: Data { key.rawRepresentation }

    func signature(for message: Data, presence: ComputerUseApprovalPresence) throws -> P256.Signing.ECDSASignature {
        try key.signature(for: message)
    }
}
