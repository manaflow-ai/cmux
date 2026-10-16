import CmuxFoundation
import Foundation
import Security

/// Where the app's headless cmux-tui links keep their client identity, and where the
/// bundled client lives. Mirrors the CLI's `vmTuiClientStateDir` / `vmTuiDevicesStoreURL`
/// (`CLI/CMUXCLI+VMTui.swift`) on purpose: the sidebar's links and the pane's
/// `cmux vm-tui-connect` must present the same device to a machine's daemon, so one
/// enrollment covers both. The CLI helpers are compiled only into the CLI target, hence
/// the duplicate paths here.
public struct CloudTuiClientPaths: Sendable {
    /// One enrolled device per machine, as the CLI stores it (`vm-tui-devices.json`).
    public struct DeviceRecord: Codable, Sendable, Equatable {
        public let deviceFingerprint: String
        public let updatedAtUnix: Int

        public init(deviceFingerprint: String, updatedAtUnix: Int) {
            self.deviceFingerprint = deviceFingerprint
            self.updatedAtUnix = updatedAtUnix
        }
    }

    /// Stored in place of a device fingerprint for a machine this Mac reaches over
    /// the trusted-carrier listener: there is no enrolled device, and the next link
    /// dials `--carrier` again with no control-plane call. A real fingerprint means
    /// the Mac enrolled before the machine's daemon served the trusted listener and
    /// keeps presenting its stored key. Mirrored by the CLI's own store.
    public static let carrierDeviceMarker = "carrier"

    public let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home
    }

    /// Per-Mac cmux-tui client state (device key, known daemons).
    public var stateDir: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("cmux-tui-client", isDirectory: true)
    }

    public var devicesStoreURL: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-tui-devices.json", isDirectory: false)
    }

    public func ensureStateDir() throws {
        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func loadDevices() -> [String: DeviceRecord] {
        guard let data = try? Data(contentsOf: devicesStoreURL),
              let store = try? JSONDecoder().decode([String: DeviceRecord].self, from: data) else {
            return [:]
        }
        return store
    }

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

    public func saveDeviceFingerprint(_ fingerprint: String, for machineID: String) {
        var store = loadDevices()
        store[machineID] = DeviceRecord(deviceFingerprint: fingerprint, updatedAtUnix: Int(Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: devicesStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: devicesStoreURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesStoreURL.path)
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
