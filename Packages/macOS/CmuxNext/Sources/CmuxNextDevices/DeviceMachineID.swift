import CryptoKit
import Foundation
#if os(macOS)
import IOKit
#endif

/// The `machineId` this device sends at registration (`POST /v1/devices`): one value for every
/// cmux build on this machine, so the hub keeps one record per machine (PROTOCOL.md, One record
/// per machine). Leo's Settings > Screen Sharing listed the Mac he sat on twice, both Offline
/// (2026-11-15): each build (NIGHTLY, DEV, tagged DEV) and each renewed identity is its own
/// device record with the same name.
///
/// It is a SHA-256 of the IOPlatformUUID, never the hardware id itself, and the hub hashes it
/// again with the account, so two accounts on one Mac get unrelated keys. Nil where there is no
/// machine identity to read (iOS: the hub folds those records by name).
enum DeviceMachineID {
    static let current: String? = {
        #if os(macOS)
        platformUUID().map(hash)
        #else
        nil
        #endif
    }()

    /// The hash of a raw machine identity, as the hub expects it (64 hex).
    static func hash(_ raw: String) -> String {
        SHA256.hash(data: Data("cmux device hub machine v1\u{0}\(raw.uppercased())".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    #if os(macOS)
    /// The IOPlatformUUID: the same for every build and bundle id on this Mac.
    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let uuid = value?.takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return uuid
    }
    #endif
}
