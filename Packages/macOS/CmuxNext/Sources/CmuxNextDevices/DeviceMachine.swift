internal import CmuxNextCompat
import CryptoKit
import Foundation
#if canImport(IOKit)
import IOKit
#endif

/// The Mac this app runs on, as the device hub's `machine` (docs/device-hub/PROTOCOL.md,
/// "Permissions are per Mac"): the lowercase hex HMAC-SHA256 of `cmux.device-hub.machine\n` and the
/// Mac's hardware UUID, keyed by a random secret kept in a file on this Mac. Every build of the
/// app in one build space (each tagged build has its own device id) and its cmux Remote read the
/// same file, so they send the same value and the host's Always answer about this Mac covers all
/// of them. A tagged dev build's value also names its build space (`\n` and `dev:<slug>` after the
/// UUID, ``DeviceHubBuildSpace``), so it is its own machine, never NIGHTLY's or another tag's; the
/// default space (NIGHTLY, release) keeps the value it always had. The hardware UUID alone is no
/// secret (any app on the Mac can read it), so the key is what stops a device elsewhere from naming
/// this Mac; nil where there is no hardware UUID (not a Mac) or no secret.
struct DeviceMachine: Sendable, Equatable {
    let id: String?

    /// This Mac's in the default build space, read once.
    /// Only a Mac names one: elsewhere there is no hardware UUID, so no secret is made either.
    static let current: DeviceMachine = DeviceMachine(hardwareUUID: platform.uuid, secret: platform.secret)

    /// This Mac's in `buildSpace`: ``current`` for the default space.
    static func current(in buildSpace: DeviceHubBuildSpace) -> DeviceMachine {
        guard let space = buildSpace.headerValue else { return current }
        return DeviceMachine(hardwareUUID: platform.uuid, secret: platform.secret, buildSpace: space)
    }

    /// The hardware UUID and the secret, read once; no secret is made where there is no UUID.
    private static let platform: (uuid: String?, secret: Data?) = {
        guard let uuid = platformUUID() else { return (nil, nil) }
        return (uuid, DeviceMachineSecret.load(at: DeviceMachineSecret.defaultURL))
    }()

    /// `buildSpace`: a dev build's `dev:<slug>`, nil for the default space.
    init(hardwareUUID: String?, secret: Data?, buildSpace: String? = nil) {
        guard let uuid = hardwareUUID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !uuid.isEmpty,
              let secret, secret.count >= 32 else {
            id = nil
            return
        }
        let message = buildSpace.map { "cmux.device-hub.machine\n\(uuid)\n\($0)" } ?? "cmux.device-hub.machine\n\(uuid)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: secret))
        id = mac.map { String(format: "%02x", $0) }.joined()
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

/// The key of ``DeviceMachine``: 32 random bytes in a file only this user can read, made once by
/// whichever cmux app runs first. The file is written whole under a temporary name and then
/// hard-linked into place, so two apps starting together both end up reading the one that won.
enum DeviceMachineSecret {
    /// `~/Library/Application Support/cmux-device-hub/machine.key`, shared by every cmux build and cmux Remote.
    /// Not a build's state root (BuildIdentity) on purpose: the one key is what makes every build name the same Mac.
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("cmux-device-hub", isDirectory: true).appendingPathComponent("machine.key")
    }

    /// The secret at `url`, made first when there is none. Nil when it can be neither read nor made.
    static func load(at url: URL) -> Data? {
        if let existing = read(url) { return existing }
        let fm = FileManager.checked
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        guard fm.createFile(atPath: temp.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { return nil }
        // link(2) fails when the name exists: the first app to get here wins, the rest read its secret.
        _ = link(temp.path, url.path)
        return read(url)
    }

    private static func read(_ url: URL) -> Data? {
        guard let data = try? Data(blockingContentsOf: url), data.count == 32 else { return nil }
        return data
    }
}
