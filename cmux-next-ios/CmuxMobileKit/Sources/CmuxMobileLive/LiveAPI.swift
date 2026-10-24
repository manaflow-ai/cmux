import Foundation
import struct CmuxMobileModel.ServiceFailureMessage
import struct CmuxMobileModel.TeamAppearance

/// The `cmux-mobile-api` HTTP surface the app uses (PROTOCOL.md "HTTP").
public struct LiveAPI: Sendable {
    public let baseURL: URL
    /// A Stack access token; `true` forces a refresh after a 401.
    let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared, accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.baseURL = baseURL
        self.session = session
        self.accessToken = accessToken
    }

    /// A Mac as `GET /v1/teams/:id/macs` and the signaling `hello` / `presence` frames report it.
    public struct Mac: Codable, Hashable, Sendable {
        public var deviceId: String
        public var name: String
        public var online: Bool
        public var lastSeenAt: String?
        public var ownerUserId: String?
        /// The Mac's team (or personal space); only `GET /v1/me/macs` sends it.
        public var teamId: String?
        /// A `presence` frame for a Mac its owner deleted (0.7.0): drop it.
        public var removed: Bool?
        /// The computer the Mac runs on (added 2026-10-21): one per computer, shared by its cmux builds.
        public var machineId: String?

        public init(deviceId: String, name: String, online: Bool, lastSeenAt: String? = nil, ownerUserId: String? = nil, teamId: String? = nil, removed: Bool? = nil,
                    machineId: String? = nil) {
            self.deviceId = deviceId
            self.name = name
            self.online = online
            self.lastSeenAt = lastSeenAt
            self.ownerUserId = ownerUserId
            self.teamId = teamId
            self.removed = removed
            self.machineId = machineId
        }

        public var lastSeenDate: Date? { lastSeenAt.flatMap(LiveAPI.parseDate) }
    }

    public struct Prefs: Codable, Hashable, Sendable {
        public var color: String?
        public var emoji: String?
        /// No filled background behind the icon. A Worker that predates it omits the key.
        public var transparent: Bool?

        public init(color: String?, emoji: String?, transparent: Bool? = nil) {
            self.color = color
            self.emoji = emoji
            self.transparent = transparent
        }

        /// The appearance these prefs describe; nil when no color is stored
        /// yet (the app keeps its local appearance then).
        public var appearance: TeamAppearance? {
            guard let color, color.hasPrefix("#") else { return nil }
            return TeamAppearance(colorHex: color, emoji: emoji, transparent: transparent ?? false)
        }
    }

    /// One of the caller's devices as `GET /v1/me/devices` reports it (0.7.0).
    public struct Device: Codable, Hashable, Sendable {
        public var deviceId: String
        public var kind: String
        public var name: String
        public var teamId: String
        /// When the account first registered the device (ISO 8601).
        public var createdAt: String?
        public var lastSeenAt: String?
        /// Live presence for a Mac; nil for a phone.
        public var online: Bool?
        /// Whether a phone has an APNs token registered.
        public var push: Bool?
        /// A Mac's machine id (added 2026-10-21); nil for phones and older hosts.
        public var machineId: String?

        public init(deviceId: String, kind: String, name: String, teamId: String, createdAt: String? = nil, lastSeenAt: String? = nil, online: Bool? = nil, push: Bool? = nil,
                    machineId: String? = nil) {
            self.machineId = machineId
            self.deviceId = deviceId
            self.kind = kind
            self.name = name
            self.teamId = teamId
            self.createdAt = createdAt
            self.lastSeenAt = lastSeenAt
            self.online = online
            self.push = push
        }

        public var lastSeenDate: Date? { lastSeenAt.flatMap(LiveAPI.parseDate) }
        public var createdDate: Date? { createdAt.flatMap(LiveAPI.parseDate) }
    }

    /// `GET /v1/ice`, for diagnostics: whether a TURN relay was included.
    public struct Ice: Decodable, Sendable {
        public var turn: Bool?
    }

    /// `{"error":{"code","message"}}` or a transport failure.
    public struct Failure: Error, Equatable, Sendable {
        public var status: Int
        public var code: String
        public var message: String
        /// The service's id for the request (support quotes it), when it sent one.
        public var requestID: String? = nil
    }

    /// `POST /v1/devices` (upsert).
    public func registerDevice(id: String, kind: String, name: String, teamID: String) async throws {
        let body: [String: Any] = ["deviceId": id, "kind": kind, "name": name, "teamId": teamID]
        _ = try await call("POST", "v1/devices", body: body)
    }

    /// `POST /v1/me/bootstrap`: the launch in one round trip. Registers `devices` in `teamID`
    /// and returns that team's Macs and the account's Macs everywhere. Nil when the service
    /// predates it (404), so the caller takes the separate calls.
    public func bootstrap(teamID: String, devices: [(id: String, kind: String, name: String)]) async throws -> (macs: [Mac], myMacs: [Mac]?)? {
        struct Part<T: Decodable>: Decodable {
            var macs: T?
            var error: Envelope.Body?
        }
        struct Envelope: Decodable { struct Body: Decodable { var code: String; var message: String } }
        struct Registered: Decodable { var device: Device?; var error: Envelope.Body? }
        struct Reply: Decodable {
            var devices: [Registered]
            var macs: Part<[Mac]>
            var myMacs: Part<[Mac]>
        }
        let body: [String: Any] = ["teamId": teamID, "devices": devices.map { ["deviceId": $0.id, "kind": $0.kind, "name": $0.name] }]
        let data: Data
        do {
            data = try await call("POST", "v1/me/bootstrap", body: body)
        } catch let failure as Failure where failure.status == 404 {
            return nil
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        for registered in reply.devices {
            if let error = registered.error { throw Failure(status: 0, code: error.code, message: error.message) }
        }
        guard let macs = reply.macs.macs else {
            throw Failure(status: 0, code: reply.macs.error?.code ?? "bad_reply", message: reply.macs.error?.message ?? "no Macs in the reply")
        }
        return (macs, reply.myMacs.macs)
    }

    /// `GET /v1/teams/:id/macs`.
    public func macs(teamID: String) async throws -> [Mac] {
        struct Reply: Decodable { var macs: [Mac] }
        return try JSONDecoder().decode(Reply.self, from: try await call("GET", "v1/teams/\(teamID)/macs")).macs
    }

    /// `GET /v1/me/macs`: the account's own Macs in every team and the personal space.
    public func myMacs() async throws -> [Mac] {
        struct Reply: Decodable { var macs: [Mac] }
        return try JSONDecoder().decode(Reply.self, from: try await call("GET", "v1/me/macs")).macs
    }

    /// `GET /v1/me/devices`: every Mac and phone this account registered.
    public func myDevices() async throws -> [Device] {
        struct Reply: Decodable { var devices: [Device] }
        return try JSONDecoder().decode(Reply.self, from: try await call("GET", "v1/me/devices")).devices
    }

    /// `DELETE /v1/devices/:id` (owner only).
    public func deleteDevice(id: String) async throws {
        _ = try await call("DELETE", "v1/devices/\(id)")
    }

    /// `PUT /v1/devices/:id/push`: this phone's APNs token and the events it wants.
    public func putPush(deviceID: String, token: String, environment: String, topic: String, kinds: [String],
                        mutedMacs: [String] = [], previews: Bool = true) async throws {
        // `mutedMacs` and `previews` are API 0.13.0; an older service ignores them.
        let body: [String: Any] = ["token": token, "environment": environment, "topic": topic, "kinds": kinds,
                                   "mutedMacs": mutedMacs, "previews": previews]
        _ = try await call("PUT", "v1/devices/\(deviceID)/push", body: body)
    }

    /// What the mailbox says about a reply (`GET /v1/devices/:mac/mailbox/:id`).
    public struct MailboxState: Decodable, Equatable, Sendable {
        /// `queued`, `applied`, `rejected` or `expired`.
        public var state: String
        public var reason: String?
        /// The Mac's identity signature over the outcome (`cmux-mobile-mailbox-ack-v1`).
        public var sig: String?

        public init(state: String, reason: String? = nil, sig: String? = nil) {
            self.state = state
            self.reason = reason
            self.sig = sig
        }
    }

    /// `POST /v1/devices/:mac/mailbox` (PROTOCOL.md "Reply mailbox"): a reply
    /// sealed to the Mac, held until its host connects. Returns whether the
    /// Mac's socket was open (it got it at once).
    public func postMailbox(macID: String, id: String, from phone: String, sealed: String) async throws -> Bool {
        struct Reply: Decodable { var queued: Bool?; var delivered: Bool? }
        let data = try await call("POST", "v1/devices/\(macID)/mailbox", body: ["id": id, "from": phone, "sealed": sealed])
        return (try? JSONDecoder().decode(Reply.self, from: data))?.delivered ?? false
    }

    /// `GET /v1/devices/:mac/mailbox/:id`.
    public func mailboxState(macID: String, id: String) async throws -> MailboxState {
        try JSONDecoder().decode(MailboxState.self, from: try await call("GET", "v1/devices/\(macID)/mailbox/\(id)"))
    }

    /// `DELETE /v1/devices/:id/push`: stop pushing to this phone.
    public func deletePush(deviceID: String) async throws {
        _ = try await call("DELETE", "v1/devices/\(deviceID)/push")
    }

    /// `DELETE /v1/me`: purges everything the service stores for this account.
    public func deleteMe() async throws {
        _ = try await call("DELETE", "v1/me")
    }

    /// `GET /v1/ice`.
    public func ice() async throws -> Ice {
        try JSONDecoder().decode(Ice.self, from: try await call("GET", "v1/ice"))
    }

    /// `GET /v1/teams/:id/prefs`.
    public func prefs(teamID: String) async throws -> Prefs {
        try JSONDecoder().decode(Prefs.self, from: try await call("GET", "v1/teams/\(teamID)/prefs"))
    }

    /// `PUT /v1/teams/:id/prefs` with the whole appearance.
    public func putPrefs(teamID: String, appearance: TeamAppearance) async throws {
        _ = try await call("PUT", "v1/teams/\(teamID)/prefs", body: Self.prefsBody(appearance))
    }

    /// The `PUT /prefs` body: the color always (the fallback when the badge is
    /// transparent), the emoji (`null` clears it to automatic) and `transparent`.
    static func prefsBody(_ appearance: TeamAppearance) -> [String: Any] {
        ["color": appearance.colorHex, "emoji": appearance.emoji ?? NSNull(), "transparent": appearance.isTransparent]
    }

    /// `POST /v1/teams/:id/invites {email}`: Stack emails the invitation.
    public func invite(teamID: String, email: String) async throws {
        _ = try await call("POST", "v1/teams/\(teamID)/invites", body: ["email": email])
    }

    /// The signaling WebSocket request for `deviceID` (bearer header, subprotocol `cmux-mobile.v1`).
    public func signalRequest(teamID: String, deviceID: String) async throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "v1/teams/\(teamID)/signal"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "deviceId", value: deviceID)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await accessToken(false))", forHTTPHeaderField: "Authorization")
        request.setValue("cmux-mobile.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // A rejected token (expired while the app slept) is refreshed once.
        for forceRefresh in [false, true] {
            request.setValue("Bearer \(try await accessToken(forceRefresh))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !forceRefresh { continue }
            guard (200..<300).contains(status) else {
                throw Self.failure(status: status, data: data, requestID: Self.requestID(response as? HTTPURLResponse))
            }
            return data
        }
        throw Failure(status: 401, code: "unauthorized", message: "token refresh failed")
    }

    static func failure(status: Int, data: Data, requestID: String? = nil) -> Failure {
        struct Envelope: Decodable {
            struct Body: Decodable { var code: String; var message: String }
            var error: Body
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return Failure(status: status, code: envelope.error.code, message: envelope.error.message, requestID: requestID)
        }
        return Failure(status: status, code: "http_\(status)", message: String(decoding: data.prefix(200), as: UTF8.self), requestID: requestID)
    }

    /// The request id the service's edge stamps on every response.
    static func requestID(_ response: HTTPURLResponse?) -> String? {
        guard let response else { return nil }
        for name in ["X-Request-Id", "CF-Ray"] {
            if let value = response.value(forHTTPHeaderField: name), !value.isEmpty { return value }
        }
        return nil
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Signaling frames the app reads (PROTOCOL.md "Signaling WebSocket").
public enum SignalFrame: Equatable, Sendable {
    case hello(you: String, macs: [LiveAPI.Mac])
    case presence(LiveAPI.Mac)
    case error(code: String, message: String)
    case other

    public static func parse(_ data: Data) -> SignalFrame? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let decoder = JSONDecoder()
        switch type {
        case "hello":
            guard let macs = object["macs"], let raw = try? JSONSerialization.data(withJSONObject: macs),
                  let list = try? decoder.decode([LiveAPI.Mac].self, from: raw) else { return nil }
            return .hello(you: object["you"] as? String ?? "", macs: list)
        case "presence":
            guard let mac = object["mac"], let raw = try? JSONSerialization.data(withJSONObject: mac),
                  let value = try? decoder.decode(LiveAPI.Mac.self, from: raw) else { return nil }
            return .presence(value)
        case "error":
            return .error(code: object["code"] as? String ?? "error", message: object["message"] as? String ?? "")
        default:
            return .other
        }
    }
}

extension LiveAPI {
    /// What a failed device removal tells the user. Never names the
    /// service's vendors; quotes the Request ID when the service sent one.
    public static func removalMessage(for error: any Error) -> ServiceFailureMessage {
        if let failure = error as? Failure {
            let text: String
            switch (failure.status, failure.code) {
            case (403, "not_owner"):
                text = "This device belongs to another account. Only the account it's signed in to can remove it."
            case (401, _):
                text = "Your session expired. Sign in again, then try again."
            case (429, _):
                text = "Too many requests. Wait a moment and try again."
            case (500..., _), (0, _):
                text = "The Cloud service couldn't remove it (\(failure.code)). Try again in a moment."
            default:
                text = "The Cloud service refused: \(failure.message.isEmpty ? failure.code : failure.message)"
            }
            return ServiceFailureMessage(text: text, requestID: failure.requestID)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return ServiceFailureMessage(text: "You're offline. Connect to the internet and try again.")
            case .timedOut:
                return ServiceFailureMessage(text: "The Cloud service didn't answer in time. Try again.")
            default:
                return ServiceFailureMessage(text: "Couldn't reach the Cloud service (\(urlError.localizedDescription)).")
            }
        }
        return ServiceFailureMessage(text: "Couldn't remove it: \(error.localizedDescription)")
    }
}
