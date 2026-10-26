import Darwin
import Foundation

/// The device records and attach routes shared by the Cloud app and CLI.
///
/// This adapter keeps the existing synchronous file contract for both processes;
/// it holds no mutable in-memory cache. Callers supply their home and tests use
/// a temporary directory. A cross-process lock serializes writes so concurrent
/// updates preserve the other machines and any omitted fields in the same file.
///
/// ```swift
/// let store = CloudTuiDeviceStore(home: temporaryHome)
/// store.saveAttachState(deviceFingerprint: "carrier", route: route, for: machineID)
/// let restored = CloudTuiDeviceStore(home: temporaryHome).loadDevices()[machineID]
/// ```
public struct CloudTuiDeviceStore: Sendable {
    /// One enrolled device per machine in `vm-tui-devices.json`.
    public struct DeviceRecord: Codable, Sendable, Equatable {
        /// The enrolled key fingerprint or trusted-carrier marker.
        public let deviceFingerprint: String
        /// Unix timestamp of the most recent update.
        public let updatedAtUnix: Int
        /// The server-advertised daemon route, retained so reconnects do not
        /// reconstruct a provider-specific port from an IP address.
        public let route: String?

        /// Creates a persisted record; a nil route represents a legacy enrollment.
        ///
        /// - Parameters:
        ///   - deviceFingerprint: The enrolled identity or carrier marker.
        ///   - updatedAtUnix: Unix timestamp of the update.
        ///   - route: Server-advertised route, absent in legacy records.
        public init(deviceFingerprint: String, updatedAtUnix: Int, route: String? = nil) {
            self.deviceFingerprint = deviceFingerprint
            self.updatedAtUnix = updatedAtUnix
            self.route = route
        }
    }

    /// Identifies a trusted-carrier listener without a separately enrolled key.
    public static let carrierDeviceMarker = "carrier"

    /// The home containing the shared Cloud client state.
    public let home: URL
    private let now: @Sendable () -> Date

    /// Creates an adapter for one home directory.
    ///
    /// - Parameters:
    ///   - home: The app/CLI home, or an isolated test directory.
    ///   - now: Clock used to timestamp stored records.
    public init(home: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.now = now
    }

    /// Per-Mac cmux-tui client state, separate from interactive cmux-tui.
    public var stateDir: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("cmux-tui-client", isDirectory: true)
    }

    /// The shared device record file, compatible with older app and CLI builds.
    public var devicesStoreURL: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-tui-devices.json", isDirectory: false)
    }

    /// Reads the current file, returning an empty store when it cannot be decoded.
    public func loadDevices() -> [String: DeviceRecord] {
        guard let data = try? Data(contentsOf: devicesStoreURL),
              let store = try? JSONDecoder().decode([String: DeviceRecord].self, from: data) else {
            return [:]
        }
        return store
    }

    /// Saves a machine's identity and route without clearing omitted fields.
    ///
    /// A route alone cannot establish trust: a new record requires an identity.
    ///
    /// - Parameters:
    ///   - deviceFingerprint: New identity, or nil to preserve the existing identity.
    ///   - route: New server route, or nil to preserve the existing route.
    ///   - machineID: The machine whose record is updated.
    public func saveAttachState(deviceFingerprint: String? = nil, route: String? = nil, for machineID: String) {
        let directory = devicesStoreURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = devicesStoreURL.appendingPathExtension("lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard lockFD >= 0 else { return }
        defer { _ = close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { return }
        defer { _ = flock(lockFD, LOCK_UN) }

        // Lock a stable sibling file: atomic JSON replacement changes the
        // store's inode, which cannot safely serve as the shared lock.
        var store = loadDevices()
        let previous = store[machineID]
        let fingerprint = deviceFingerprint ?? previous?.deviceFingerprint
        guard let fingerprint, !fingerprint.isEmpty else { return }
        store[machineID] = DeviceRecord(
            deviceFingerprint: fingerprint,
            updatedAtUnix: Int(now().timeIntervalSince1970),
            route: route ?? previous?.route
        )
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: devicesStoreURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesStoreURL.path)
    }
}
