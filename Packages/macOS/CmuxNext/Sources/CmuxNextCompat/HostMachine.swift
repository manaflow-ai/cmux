#if canImport(CryptoKit)
public import Foundation
import CryptoKit

/// This computer, as far as files a build keeps are concerned: its host UUID (`gethostuuid`, the
/// IOPlatformUUID every build reads alike), which a Migration Assistant transfer or a restore to
/// another Mac does not carry over.
///
/// An id a build keeps in a plain file (the iPhone host's device id, the Cloud install id) travels
/// with the folder; the Keychain items and Secure Enclave keys beside it do not (they are
/// `ThisDeviceOnly`). Each such id records the ``stamp(purpose:)`` of the computer it was made on, so
/// a copied folder is recognized and the new Mac becomes a new device instead of a second copy of
/// the old one. The hardware id itself is never written: only a keyed hash of it.
public struct HostMachine: Sendable, Equatable {
    /// The 16-byte host UUID.
    public let uuid: Data

    public init(uuid: Data) {
        self.uuid = uuid
    }

    /// This computer, or nil when the system does not say (a sandbox that refuses it): then no
    /// copy check is made and stored ids are kept.
    public static func current() -> HostMachine? {
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        let ok = withUnsafeMutablePointer(to: &raw) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: 16) { gethostuuid($0, &wait) }
        } == 0
        let id = withUnsafeBytes(of: raw) { Data($0) }
        guard ok, id.contains(where: { $0 != 0 }) else { return nil }
        return HostMachine(uuid: id)
    }

    /// A keyed hash naming this computer for one purpose (HMAC-SHA256 of the host UUID under
    /// `purpose`, first 16 bytes in lowercase hex): different purposes give unrelated values, and
    /// the hardware id cannot be read back from it.
    public func stamp(purpose: String) -> String {
        let tag = HMAC<SHA256>.authenticationCode(for: uuid, using: SymmetricKey(data: Data(purpose.utf8)))
        return Data(tag).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
