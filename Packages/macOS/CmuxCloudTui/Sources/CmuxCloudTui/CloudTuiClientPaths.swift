import CmuxCloudMachines
import CmuxFoundation
import Foundation
import Security

/// Where the app's headless cmux-tui links and CLI keep their shared client identity,
/// device records, and server-advertised attach routes.
public struct CloudTuiClientPaths: Sendable {
    /// The shared persisted record used by the app and CLI.
    public typealias DeviceRecord = CloudTuiDeviceStore.DeviceRecord

    /// The shared trusted-carrier identity marker.
    public static let carrierDeviceMarker = CloudTuiDeviceStore.carrierDeviceMarker

    private var deviceStore: CloudTuiDeviceStore { CloudTuiDeviceStore(home: home) }

    public let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home
    }

    /// Per-Mac cmux-tui client state (device key, known daemons).
    public var stateDir: URL { deviceStore.stateDir }

    public var devicesStoreURL: URL { deviceStore.devicesStoreURL }

    public func ensureStateDir() throws {
        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func loadDevices() -> [String: DeviceRecord] { deviceStore.loadDevices() }

    /// This Mac's durable notification client id (`notification.ack` `client_id`),
    /// one per install: `mac-` plus 32 hex digits, minted on first use and kept in
    /// the client state dir beside the device key. Every machine sees the same id,
    /// so per-client read state follows the install, not the machine.
    public var notificationClientIDURL: URL {
        stateDir.appendingPathComponent("notification-client-id", isDirectory: false)
    }

    public func notificationClientID() -> String {
        if let existing = try? String(contentsOf: notificationClientIDURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isValidNotificationClientID(trimmed) { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let minted = "mac-" + bytes.map { String(format: "%02x", $0) }.joined()
        try? ensureStateDir()
        try? minted.write(to: notificationClientIDURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notificationClientIDURL.path)
        return minted
    }

    /// The daemon's rule: 1 to 128 printable ASCII bytes, no spaces.
    public static func isValidNotificationClientID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f }
    }

    public func deviceFingerprint(for machineID: String) -> String? {
        loadDevices()[machineID]?.deviceFingerprint
    }

    /// The last server-advertised attach route for a machine, if one exists.
    public func route(for machineID: String) -> String? {
        loadDevices()[machineID]?.route
    }

    public func saveDeviceFingerprint(_ fingerprint: String, for machineID: String) {
        deviceStore.saveAttachState(deviceFingerprint: fingerprint, for: machineID)
    }

    /// Persists the device identity and attach route together. The route is
    /// optional so records written by older builds remain valid migrations.
    public func saveAttachState(deviceFingerprint: String? = nil, route: String? = nil, for machineID: String) {
        deviceStore.saveAttachState(deviceFingerprint: deviceFingerprint, route: route, for: machineID)
    }

    /// The app and CLI share a local label that never needs hostname resolution.
    public static func deviceName(hostName: String? = nil) -> String {
        (hostName.map { RemoteClientDeviceName(hostName: $0) } ?? RemoteClientDeviceName()).value
    }

    /// The cmux-tui client the app drives: the bundled one
    /// (`Contents/Resources/bin/cmux-tui`, installed by scripts/install-cmux-tui-client.sh),
    /// else `CMUX_TUI_CLIENT`. No PATH search: the app must not pick up a stray binary.
    public static func clientURL(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fm = FileManager.default
        if let bundled = bundle.resourceURL?.appendingPathComponent("bin/cmux-tui"),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if let explicit = environment["CMUX_TUI_CLIENT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty, fm.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        return nil
    }
}
