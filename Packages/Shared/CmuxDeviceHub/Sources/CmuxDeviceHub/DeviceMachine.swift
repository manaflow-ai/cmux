import CryptoKit
import Foundation
#if canImport(IOKit)
import IOKit
#endif

/// The Mac this app runs on, as the device hub's `machine` (docs/device-hub/PROTOCOL.md,
/// "Permissions are per Mac"): the lowercase hex SHA-256 of `cmux.device-hub.machine\n` and the
/// Mac's hardware UUID. Every build of the app (each tagged build has its own device id) and cmux
/// Remote send the same value, so the host's Always answer about this Mac covers all of them.
/// Only a hash leaves the Mac; nil where there is no hardware UUID (not a Mac).
struct DeviceMachine: Sendable, Equatable {
    let id: String?

    /// This Mac's, read once.
    static let current = DeviceMachine(hardwareUUID: Self.platformUUID())

    init(hardwareUUID: String?) {
        guard let uuid = hardwareUUID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !uuid.isEmpty else {
            id = nil
            return
        }
        id = SHA256.hash(data: Data("cmux.device-hub.machine\n\(uuid)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// IOPlatformExpertDevice's IOPlatformUUID: the same for every app and user on this Mac.
    private static func platformUUID() -> String? {
        #if canImport(IOKit) && os(macOS)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        #else
        return nil
        #endif
    }
}
