import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "push")

/// This phone's APNs registration with the service (PROTOCOL.md
/// `PUT /v1/devices/:id/push`): the token from the app delegate, the device
/// id it belongs to (registered with the active team), and which events the
/// user wants (Settings → Notifications). Sends whenever one of them changes.
@MainActor
public final class PushRegistration {
    public static let shared = PushRegistration()

    /// Event kinds the Mac reports: `question`, `permission`, `completed`, `failed`, `chief`, `terminal`.
    public static let allKinds = ["question", "permission", "completed", "failed", "chief", "terminal"]

    /// What Settings → Notifications asks the service for.
    public struct Preferences: Equatable, Sendable {
        public var kinds: [String]
        public var mutedMacs: [String]
        public var previews: Bool

        public init(kinds: [String], mutedMacs: [String] = [], previews: Bool = true) {
            self.kinds = kinds
            self.mutedMacs = mutedMacs
            self.previews = previews
        }

        var key: String { [kinds.joined(separator: ","), mutedMacs.sorted().joined(separator: ","), previews ? "p" : "-"].joined(separator: "|") }
    }

    private var token: String?
    private var api: LiveAPI?
    private var deviceID: String?
    private var preferences = Preferences(kinds: ["question", "permission", "completed", "chief"])
    /// What the service last accepted, so a repeat sends nothing.
    private var sent: String?
    private var task: Task<Void, Never>?

    init() {}

    /// The APNs device token (app delegate).
    public func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        sync()
    }

    /// The service and this phone's registered device id (after team registration).
    public func attach(api: LiveAPI, deviceID: String) {
        self.api = api
        self.deviceID = deviceID
        sync()
    }

    public func setPreferences(_ preferences: Preferences) {
        self.preferences = preferences
        sync()
    }

    /// Sign-out: the service stops pushing to this phone. Runs while the
    /// session is still valid.
    public func unregister() async {
        task?.cancel()
        defer {
            api = nil
            deviceID = nil
            sent = nil
        }
        guard let api, let deviceID, sent != nil else { return }
        do {
            try await api.deletePush(deviceID: deviceID)
        } catch {
            log.error("push unregister failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sync() {
        guard let api, let deviceID, let token, let topic = Bundle.main.bundleIdentifier else { return }
        let environment = Self.environment
        let key = [deviceID, token, environment, preferences.key].joined(separator: "|")
        guard key != sent else { return }
        let preferences = preferences
        task?.cancel()
        task = Task { [weak self] in
            do {
                try await api.putPush(deviceID: deviceID, token: token, environment: environment, topic: topic, kinds: preferences.kinds,
                                      mutedMacs: preferences.mutedMacs, previews: preferences.previews)
                guard !Task.isCancelled else { return }
                self?.sent = key
                log.info("push registered (\(environment, privacy: .public), \(preferences.kinds.count, privacy: .public) kinds)")
            } catch {
                log.error("push register failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The APNs environment this build's signature uses: a development
    /// provisioning profile (Xcode and hand-installed builds) says
    /// `development`, so APNs is the sandbox; App Store and TestFlight builds
    /// carry no embedded profile and use production.
    static let environment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return "production" }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "<key>aps-environment</key>") else { return "sandbox" }
        let rest = text[range.upperBound...].prefix(80)
        return rest.contains("<string>production</string>") ? "production" : "sandbox"
        #endif
    }()
}
