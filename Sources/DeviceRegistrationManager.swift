import Foundation

/// Manages device registration with Convex backend.
/// Registers on launch, sends periodic heartbeats, marks offline on quit.
final class DeviceRegistrationManager: @unchecked Sendable {
    private let client: ConvexHTTPClient
    private let deviceId: String
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 60

    private static let deviceIdKey = "com.cmux.deviceId"

    init(client: ConvexHTTPClient) {
        self.client = client

        let defaults = UserDefaults.standard
        if let existingId = defaults.string(forKey: Self.deviceIdKey) {
            self.deviceId = existingId
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: Self.deviceIdKey)
            self.deviceId = newId
        }
    }

    /// Start registration and heartbeat. Call on app launch.
    func start() async {
        await register()
        startHeartbeat()
    }

    /// Stop heartbeat and mark offline. Call on app quit/sleep.
    func stop() async {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        do {
            try await client.markOffline(deviceId: deviceId)
        } catch {
            NSLog("DeviceRegistrationManager: failed to mark offline: \(error)")
        }
    }

    /// Report a terminal event to Convex.
    func reportEvent(_ event: TerminalEvent) async {
        do {
            try await client.sendEvent(event)
        } catch {
            NSLog("DeviceRegistrationManager: failed to send event: \(error)")
        }
    }

    /// Sync current workspace list to Convex.
    func syncWorkspaces(_ workspaces: [WorkspaceSnapshot]) async {
        do {
            try await client.syncWorkspaces(deviceId: deviceId, workspaces: workspaces)
        } catch {
            NSLog("DeviceRegistrationManager: failed to sync workspaces: \(error)")
        }
    }

    // MARK: - Private

    private func register() async {
        let hostname = ProcessInfo.processInfo.hostName
        let tailscaleHostname = TailscaleInfo.hostname()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

        let registration = DeviceRegistration(
            deviceId: deviceId,
            hostname: hostname,
            tailscaleHostname: tailscaleHostname,
            sshPort: 22,
            capabilities: ["terminal", "notifications", "workspaces"],
            osVersion: osVersion,
            appVersion: appVersion
        )

        do {
            try await client.registerDevice(registration)
        } catch {
            NSLog("DeviceRegistrationManager: failed to register device: \(error)")
        }
    }

    private func startHeartbeat() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: self.heartbeatInterval,
                repeats: true
            ) { [weak self] _ in
                guard let self else { return }
                Task {
                    do {
                        try await self.client.heartbeat(deviceId: self.deviceId)
                    } catch {
                        NSLog("DeviceRegistrationManager: heartbeat failed: \(error)")
                    }
                }
            }
        }
    }
}
