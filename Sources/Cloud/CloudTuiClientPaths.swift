import Foundation

/// Where the app's headless cmux-tui links keep their client identity, and where the
/// bundled client lives. Mirrors the CLI's `vmTuiClientStateDir` / `vmTuiDevicesStoreURL`
/// (`CLI/CMUXCLI+VMTui.swift`) on purpose: the sidebar's links and the pane's
/// `cmux vm-tui-connect` must present the same device to a machine's daemon, so one
/// enrollment covers both. The CLI helpers are compiled only into the CLI target, hence
/// the duplicate paths here.
struct CloudTuiClientPaths: Sendable {
    /// One enrolled device per machine, as the CLI stores it (`vm-tui-devices.json`).
    struct DeviceRecord: Codable, Sendable, Equatable {
        let deviceFingerprint: String
        let updatedAtUnix: Int
    }

    let home: URL

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home
    }

    /// Per-Mac cmux-tui client state (device key, known daemons).
    var stateDir: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("cmux-tui-client", isDirectory: true)
    }

    var devicesStoreURL: URL {
        home.appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-tui-devices.json", isDirectory: false)
    }

    func ensureStateDir() throws {
        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func loadDevices() -> [String: DeviceRecord] {
        guard let data = try? Data(contentsOf: devicesStoreURL),
              let store = try? JSONDecoder().decode([String: DeviceRecord].self, from: data) else {
            return [:]
        }
        return store
    }

    func deviceFingerprint(for machineID: String) -> String? {
        loadDevices()[machineID]?.deviceFingerprint
    }

    func saveDeviceFingerprint(_ fingerprint: String, for machineID: String) {
        var store = loadDevices()
        store[machineID] = DeviceRecord(deviceFingerprint: fingerprint, updatedAtUnix: Int(Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: devicesStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: devicesStoreURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesStoreURL.path)
    }

    /// The device name a machine's daemon shows for this Mac; same derivation as the CLI.
    static func deviceName(hostName: String = ProcessInfo.processInfo.hostName) -> String {
        let raw = hostName.split(separator: ".").first.map(String.init) ?? "mac"
        let cleaned = raw.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : Character("-") }
        return "cmux-" + String(cleaned).prefix(40)
    }

    /// The cmux-tui client the app drives: the bundled one
    /// (`Contents/Resources/bin/cmux-tui`, installed by scripts/install-cmux-tui-client.sh),
    /// else `CMUX_TUI_CLIENT`. No PATH search: the app must not pick up a stray binary.
    static func clientURL(
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
