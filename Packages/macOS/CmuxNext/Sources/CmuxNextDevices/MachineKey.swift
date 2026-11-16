public import Foundation
import CryptoKit
import IOKit

/// The `machineKey` this Mac registers with (PROTOCOL.md, One record per machine): the lowercase hex
/// SHA-256 of `"cmux-device-hub machine v1\n"` and the Mac's IOPlatformUUID. Every build on the Mac
/// (NIGHTLY, DEV, tagged DEV) sends the same key, so the hub lists their records under one machine id;
/// the raw hardware id never leaves the Mac, and the hub salts the key with the account before it
/// stores or lists it.
public enum MachineKey {
    /// This Mac's key, or nil when IOKit has no platform UUID (the hub then keys by name, as before).
    public static let current: String? = platformUUID().map(key(platformUUID:))

    /// The key for one platform UUID (uppercased first, as IOKit answers it).
    public static func key(platformUUID: String) -> String {
        let digest = SHA256.hash(data: Data("cmux-device-hub machine v1\n\(platformUUID.uppercased())".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let uuid = value?.takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return uuid
    }
}
