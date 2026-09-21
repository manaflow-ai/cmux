import CmuxAuthRuntime
import AppKit
import Foundation
import Observation

/// Maintains the team presence stream and projects it into workspace viewers.
/// The Durable Object remains the authority; this model only holds an
/// in-memory, reconnectable view for the right-sidebar chrome.
@MainActor
@Observable
final class WorkspacePresenceController {
    enum Phase: Equatable, Sendable {
        case unavailable
        case connecting
        case connected
        case reconnecting
    }

    private struct WireInstance: Decodable, Equatable {
        let deviceID: String
        let tag: String
        let workspaceID: String?
        let viewerID: String?
        let displayName: String?
        let avatarURL: URL?
        let online: Bool
        let lastSeenAt: Date

        private enum CodingKeys: String, CodingKey {
            case deviceID = "deviceId"
            case tag
            case workspaceID = "workspaceId"
            case viewerID = "viewerId"
            case displayName = "viewerDisplayName"
            case avatarURL = "viewerAvatarURL"
            case online
            case lastSeenAt
        }

        init(
            deviceID: String,
            tag: String,
            workspaceID: String?,
            viewerID: String?,
            displayName: String?,
            avatarURL: URL?,
            online: Bool,
            lastSeenAt: Date
        ) {
            self.deviceID = deviceID
            self.tag = tag
            self.workspaceID = workspaceID
            self.viewerID = viewerID
            self.displayName = displayName
            self.avatarURL = avatarURL
            self.online = online
            self.lastSeenAt = lastSeenAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceID = try container.decode(String.self, forKey: .deviceID)
            tag = try container.decode(String.self, forKey: .tag)
            workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
            viewerID = try container.decodeIfPresent(String.self, forKey: .viewerID)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            let rawAvatar = try container.decodeIfPresent(String.self, forKey: .avatarURL)
            avatarURL = rawAvatar.flatMap(URL.init(string:))
            online = try container.decode(Bool.self, forKey: .online)
            let milliseconds = try container.decode(Double.self, forKey: .lastSeenAt)
            lastSeenAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        }
    }

    private enum WireMessage: Decodable {
        case snapshot([WireInstance])
        case instance(WireInstance)
        case seen(deviceID: String, tag: String, lastSeenAt: Date)
        case offline(WireInstance)

        private enum CodingKeys: String, CodingKey {
            case type
            case devices
            case instance
            case deviceID = "deviceId"
            case tag
            case lastSeenAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "snapshot":
                let devices = try container.decodeIfPresent([WireDevice].self, forKey: .devices) ?? []
                self = .snapshot(devices.flatMap(\.instances))
            case "online", "changed", "routes":
                self = .instance(try container.decode(WireInstance.self, forKey: .instance))
            case "offline":
                self = .offline(try container.decode(WireInstance.self, forKey: .instance))
            case "seen":
                let milliseconds = try container.decode(Double.self, forKey: .lastSeenAt)
                self = .seen(
                    deviceID: try container.decode(String.self, forKey: .deviceID),
                    tag: try container.decode(String.self, forKey: .tag),
                    lastSeenAt: Date(timeIntervalSince1970: milliseconds / 1_000)
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown workspace presence message"
                )
            }
        }
    }

    private struct WireDevice: Decodable {
        let instances: [WireInstance]
    }

    private(set) var phase: Phase = .unavailable
    private(set) var activeWorkspaceScope: String?
    private var lastActiveWorkspaceScope: String?
    private var records: [String: WireInstance] = [:]
    private var auth: AuthCoordinator?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var authLifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    deinit {
        streamTask?.cancel()
        authLifecycleTask?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Inject the authenticated session owner and begin lifecycle observation.
    func configure(auth: AuthCoordinator) {
        guard self.auth !== auth else { return }
        self.auth = auth
        authLifecycleTask?.cancel()
        authLifecycleTask = Task { @MainActor [weak self, weak auth] in
            guard let auth else { return }
            for await identity in auth.authenticatedSessionIdentities() {
                guard let self, !Task.isCancelled else { return }
                self.handleAuthentication(identity?.accountID)
            }
        }
        installObserversIfNeeded()
        handleAuthentication(auth.authenticatedSessionIdentity?.accountID)
    }

    /// Announces the active workspace to the shared Mac heartbeat and updates
    /// the projection used by the right-sidebar strip.
    func setActiveWorkspaceScope(_ scope: String?) {
        let trimmed = scope?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed?.isEmpty == false ? trimmed : nil
        guard activeWorkspaceScope != next else { return }
        activeWorkspaceScope = next
        if next != nil { lastActiveWorkspaceScope = next }
        PresenceHeartbeatClient.shared.setActiveWorkspaceScope(next)
    }

    /// Returns distinct online collaborators for one canonical workspace scope.
    func collaborators(for scope: String?) -> [WorkspacePresenceParticipant] {
        guard let scope, !scope.isEmpty else { return [] }
        let instances = records.values.filter { $0.online && $0.workspaceID == scope }.map {
            WorkspacePresenceParticipant(
                id: "\($0.deviceID):\($0.tag):\($0.viewerID ?? "anonymous")",
                viewerID: $0.viewerID,
                displayName: $0.displayName,
                avatarURL: $0.avatarURL,
                deviceID: $0.deviceID,
                tag: $0.tag,
                lastSeenAt: $0.lastSeenAt
            )
        }
        return WorkspacePresencePolicy.participants(
            from: instances,
            currentViewerID: auth?.currentUser?.id
        )
    }

    /// Whether the service has an authoritative snapshot for this workspace.
    func isAvailable(for scope: String?) -> Bool {
        guard let scope, !scope.isEmpty else { return false }
        return activeWorkspaceScope == scope && phase == .connected
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            .cmuxCloudTeamScopeDidChange,
            UserDefaults.didChangeNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSApplication.didResignActiveNotification {
                        self.activeWorkspaceScope = nil
                        PresenceHeartbeatClient.shared.setActiveWorkspaceScope(nil)
                    } else if name == NSApplication.didBecomeActiveNotification,
                              let scope = self.lastActiveWorkspaceScope {
                        self.activeWorkspaceScope = scope
                        PresenceHeartbeatClient.shared.setActiveWorkspaceScope(scope)
                    } else {
                        self.restartStream()
                    }
                }
            }
        }
    }

    private func handleAuthentication(_ accountID: String?) {
        if accountID == nil || !PresenceSettings.isEnabled() {
            stopStream()
            records.removeAll()
            phase = .unavailable
            return
        }
        startStreamIfNeeded()
    }

    private func restartStream() {
        stopStream()
        records.removeAll()
        phase = .unavailable
        handleAuthentication(auth?.authenticatedSessionIdentity?.accountID)
    }

    private func startStreamIfNeeded() {
        guard streamTask == nil, auth?.isAuthenticated == true else { return }
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let auth = self.auth,
                      auth.isAuthenticated,
                      PresenceSettings.isEnabled(),
                      let baseURL = PresenceHeartbeatClient.resolvedServiceURL(),
                      let accessToken = try? await auth.currentTokens().accessToken,
                      let url = Self.subscribeURL(baseURL: baseURL),
                      let teamID = auth.resolvedTeamID else {
                    self.phase = .unavailable
                    return
                }
                self.phase = self.records.isEmpty ? .connecting : .reconnecting
                let task = URLSession.shared.webSocketTask(with: Self.request(
                    url: url,
                    token: accessToken,
                    teamID: teamID
                ))
                task.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let raw): data = raw
                        @unknown default: continue
                        }
                        self.apply(data)
                        self.phase = .connected
                    }
                } catch {
                    task.cancel(with: .goingAway, reason: nil)
                }
                guard !Task.isCancelled else { return }
                self.phase = .reconnecting
                try? await ContinuousClock().sleep(for: .seconds(1))
            }
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func apply(_ data: Data) {
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        switch message {
        case .snapshot(let instances):
            records = Dictionary(uniqueKeysWithValues: instances.map { (key(for: $0), $0) })
        case .instance(let instance):
            records[key(for: instance)] = instance
        case .offline(let instance):
            records[key(for: instance)] = instance
        case .seen(let deviceID, let tag, let lastSeenAt):
            let key = "\(deviceID):\(tag)"
            guard var instance = records[key] else { return }
            instance = WireInstance(
                deviceID: instance.deviceID,
                tag: instance.tag,
                workspaceID: instance.workspaceID,
                viewerID: instance.viewerID,
                displayName: instance.displayName,
                avatarURL: instance.avatarURL,
                online: instance.online,
                lastSeenAt: lastSeenAt
            )
            records[key] = instance
        }
    }

    private func key(for instance: WireInstance) -> String {
        "\(instance.deviceID):\(instance.tag)"
    }

    private static func subscribeURL(baseURL: URL) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        switch components?.scheme?.lowercased() {
        case "https": components?.scheme = "wss"
        case "http": components?.scheme = "ws"
        default: return nil
        }
        guard var components else { return nil }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = path + "/v1/presence/subscribe"
        return components.url
    }

    private static func request(url: URL, token: String, teamID: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        return request
    }
}
