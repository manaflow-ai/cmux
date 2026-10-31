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
    private var serverStateUncertain = false
    /// The event kinds of the registration the service last accepted; nil
    /// when none is (no token, not signed in, signed out).
    public private(set) var acceptedKinds: Set<String>?

    /// Whether the service pushes this phone Chief's replies (`chief`), so
    /// the app must not alert them itself as well (``ChiefAlerts``).
    public var receivesChiefPushes: Bool { acceptedKinds?.contains("chief") == true }
    private(set) var task: Task<Void, Never>?
    private var taskID: UUID?
    private var pending: Registration?
    private let topic: String?
    private let register: @MainActor (Registration) async throws -> Void
    private let delete: @MainActor (LiveAPI, String) async throws -> Void

    struct Registration {
        let api: LiveAPI
        let deviceID: String
        let token: String
        let environment: String
        let topic: String
        let preferences: Preferences

        var key: String { [deviceID, token, environment, preferences.key].joined(separator: "|") }
    }

    init(topic: String? = Bundle.main.bundleIdentifier,
         register: @escaping @MainActor (Registration) async throws -> Void = { registration in
             try await registration.api.putPush(deviceID: registration.deviceID, token: registration.token,
                                                environment: registration.environment, topic: registration.topic,
                                                kinds: registration.preferences.kinds, mutedMacs: registration.preferences.mutedMacs,
                                                previews: registration.preferences.previews)
         },
         delete: @escaping @MainActor (LiveAPI, String) async throws -> Void = { api, deviceID in
             try await api.deletePush(deviceID: deviceID)
         }) {
        self.topic = topic
        self.register = register
        self.delete = delete
    }

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
        let inFlight = task
        let oldAPI = api
        let oldDeviceID = deviceID
        // Disarm registration synchronously, before awaiting the last PUT. Its
        // completion may still change the server even if the request is cancelled.
        task = nil
        taskID = nil
        pending = nil
        api = nil
        deviceID = nil
        sent = nil
        acceptedKinds = nil
        serverStateUncertain = false
        // Let the in-flight PUT settle before DELETE; otherwise a late PUT can
        // restore the token after sign-out. The generation guard stops new PUTs.
        await inFlight?.value
        // A previous launch may have registered this device even when this
        // process has never received an APNs token or completed a PUT.
        guard let oldAPI, let oldDeviceID else { return }
        do {
            try await delete(oldAPI, oldDeviceID)
        } catch {
            log.error("push unregister failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sync() {
        guard let api, let deviceID, let token, let topic else { return }
        let registration = Registration(api: api, deviceID: deviceID, token: token, environment: Self.environment,
                                        topic: topic, preferences: preferences)
        // A write in flight may replace `sent` on the server. Keep the latest
        // desired value even when it matches the previously accepted value.
        if task != nil {
            pending = registration
            return
        }
        guard registration.key != sent || serverStateUncertain else { return }
        pending = registration
        let id = UUID()
        taskID = id
        task = Task { [weak self] in
            await self?.sendPending(id: id)
        }
    }

    private func sendPending(id: UUID) async {
        defer {
            if taskID == id {
                task = nil
                taskID = nil
            }
        }
        // Drain changes triggered by callers, without a timer or retry loop.
        // Serial PUTs cannot overtake one another; cancellation cannot undo an
        // already accepted server mutation.
        while taskID == id, !Task.isCancelled, let registration = pending {
            pending = nil
            guard registration.key != sent || serverStateUncertain else { continue }
            do {
                try await register(registration)
                guard taskID == id, !Task.isCancelled else { return }
                sent = registration.key
                acceptedKinds = Set(registration.preferences.kinds)
                serverStateUncertain = false
                log.info("push registered (\(registration.environment, privacy: .public), \(registration.preferences.kinds.count, privacy: .public) kinds)")
            } catch {
                guard taskID == id, !Task.isCancelled else { return }
                // A lost response does not prove the server rejected the PUT.
                // Reconcile a newer value, but do not retry this one forever.
                serverStateUncertain = true
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
