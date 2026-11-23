public import CMUXAuthCore
public import CmuxMobileModel
import Foundation

/// One of the user's Cloud Chiefs (`chief.list`, `HomeChief`), the fields the
/// phone reads. Ported from the Mac (CmuxNextApp `Chief/CloudChiefs.swift`).
/// `brainPlace` names the paired server whose install answers as this chief;
/// nil means the Cloud brain answers (when its owner turned it on).
public struct CloudChief: Sendable, Equatable {
    public struct BrainPlace: Sendable, Equatable {
        public var host: String
        public var install: String
    }

    public var id: String
    public var displayName: String
    public var isDefault: Bool
    public var mainConversation: String?
    public var rev: Int
    public var brainPlace: BrainPlace?

    /// One `HomeChief` value; nil when a required field is missing.
    static func parse(_ value: Any?) -> CloudChief? {
        guard let value = value as? [String: Any], let id = value["id"] as? String,
              let rev = (value["rev"] as? NSNumber)?.intValue else { return nil }
        var place: BrainPlace?
        if let raw = value["brain_place"] as? [String: Any], let host = raw["host"] as? String, let install = raw["install"] as? String {
            place = BrainPlace(host: host, install: install)
        }
        let main = (value["main_conversation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CloudChief(id: id, displayName: value["display_name"] as? String ?? "", isDefault: value["is_default"] as? Bool ?? false,
                          mainConversation: main, rev: rev, brainPlace: place)
    }

    /// The active chiefs of a `chief.list` value (archived ones are never listed by default).
    static func parseList(_ value: Any?) -> [CloudChief] {
        guard let value = value as? [String: Any], let chiefs = value["chiefs"] as? [Any] else { return [] }
        return chiefs.compactMap(parse)
    }

    /// The chief the phone talks to: the default one with a main
    /// conversation, else the first with one (the Mac's
    /// `HomeChiefSource.choose` with no local Chief history on the phone).
    static func preferred(in chiefs: [CloudChief]) -> CloudChief? {
        let reachable = chiefs.filter { $0.mainConversation != nil }
        return reachable.first(where: \.isDefault) ?? reachable.first
    }

    /// The conversation's identity: this account as `user_<id>`, the chief as its agent id.
    func identity(userID: String) -> ChiefIdentity {
        ChiefIdentity(meID: userID.hasPrefix("user_") ? userID : "user_\(userID)", chiefID: id,
                      title: displayName.isEmpty ? ChiefIdentity.standard.title : displayName)
    }
}

/// Where the Cloud service is (``CloudBackendOverride/cloudService(environment:infoValue:defaults:debug:)``):
/// in DEBUG builds first this launch's `CMUX_NEXT_CLOUD_BACKEND` (the tag's hand-off, `review.sh
/// --backend`; allowlisted), then a rig's `CMUX_MOBILE_CLOUD_API_BASE`, then the backend an earlier
/// launch's `CMUX_NEXT_CLOUD_BACKEND` kept; in every build, `CmuxMobileCloudAPIBase` in Info.plist
/// (project.yml `CMUX_MOBILE_CLOUD_API_BASE`). Release, TestFlight and App Store builds read only
/// Info.plist. Empty: this build has no Cloud Chief.
public struct ChiefCloudConfig: Sendable, Equatable {
    public var baseURL: URL
    /// Where ``baseURL`` came from (Settings > Developer, the DEBUG readiness receipt).
    public var source: CloudBackendOverride.Source
    /// The build's cloud data space: a dev build's `X-Cmux-Build-Space` on every request and socket
    /// upgrade to the Cloud service; a misconfigured dev build's are refused. The app's composition
    /// root decides it.
    public var buildSpace: CMUXBuildSpaceState

    public init(baseURL: URL, source: CloudBackendOverride.Source = .build, buildSpace: CMUXBuildSpaceState = .nightly) {
        self.baseURL = baseURL
        self.source = source
        self.buildSpace = buildSpace
    }

    /// The configured Cloud service, its requests in `buildSpace`.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               bundle: Bundle = .main, defaults: UserDefaults = .standard,
                               buildSpace: CMUXBuildSpaceState) -> ChiefCloudConfig? {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return CloudBackendOverride.cloudService(environment: environment,
                                                 infoValue: bundle.object(forInfoDictionaryKey: "CmuxMobileCloudAPIBase") as? String,
                                                 defaults: defaults, debug: debug)
            .map { ChiefCloudConfig(baseURL: $0.url, source: $0.source, buildSpace: buildSpace) }
    }
}

/// The Cloud service as the signed-in user: the bearer is the account's
/// access token (`authorization: Bearer`), refreshed once after a 401.
/// Bodies and replies are bytes, so callers parse them in their own isolation.
struct ChiefCloudHTTP: Sendable {
    let base: URL
    let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    var session: URLSession = .shared
    /// The build's cloud data space: every request and socket upgrade to the Worker carries it, and a
    /// misconfigured dev build's throw ``CMUXBuildSpaceError`` before they are sent.
    var buildSpace: CMUXBuildSpaceState = .nightly

    struct Reply: Sendable {
        var status: Int
        var body: Data
    }

    func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)?.absoluteURL ?? base.appendingPathComponent(path)
    }

    /// `method path` with the bearer; one retry with a fresh token after a 401. `team` names the
    /// Cloud team the request acts in (`x-cmux-team`); without it a session acts in its personal team.
    /// `timeout`: how long the request may take; a request the service holds asks for more than 20 s.
    func send(_ method: String, _ path: String, body: Data? = nil, team: String? = nil, timeout: TimeInterval = 20) async throws -> Reply {
        var forceRefresh = false
        while true {
            let token = try await accessToken(forceRefresh)
            let request = try makeRequest(method, path, token: token, body: body, team: team, timeout: timeout)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !forceRefresh {
                forceRefresh = true
                continue
            }
            return Reply(status: status, body: data)
        }
    }

    /// The request ``send(_:_:body:team:timeout:)`` sends with `token`.
    func makeRequest(_ method: String, _ path: String, token: String, body: Data? = nil, team: String? = nil,
                     timeout: TimeInterval = 20) throws -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        if let team { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = body
        }
        try buildSpace.apply(to: &request)
        return request
    }

    /// A `cmux.wire.v1` socket upgrade to `url` with `token`.
    func socketRequest(_ url: URL, token: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("cmux.wire.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        try buildSpace.apply(to: &request)
        return request
    }

    /// A file's bytes to the URL an attachment intent answered with (its `method` and
    /// `headers`). Only the Worker's own URL gets the bearer: a presigned bucket URL is signed
    /// by its query and must not carry one.
    func upload(_ url: URL, method: String, headers: [String: String], body: Data, toWorker: Bool) async throws -> Reply {
        var forceRefresh = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 60
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if toWorker {
                request.setValue("Bearer \(try await accessToken(forceRefresh))", forHTTPHeaderField: "authorization")
                // A presigned bucket URL gets neither the bearer nor the build space.
                try buildSpace.apply(to: &request)
            }
            let (data, response) = try await session.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, toWorker, !forceRefresh {
                forceRefresh = true
                continue
            }
            return Reply(status: status, body: data)
        }
    }

    /// The bearer for a socket upgrade.
    func token(forceRefresh: Bool) async throws -> String {
        try await accessToken(forceRefresh)
    }

    /// The `value` of a `/v1/read` or `/v1/ops` reply, or the owner's refusal.
    static func value(_ reply: Reply) throws -> Any? {
        let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        let error = (object?["error"] as? [String: Any]) ?? (object?["_tag"] != nil ? object : nil)
        if let error, let code = error["code"] as? String {
            throw ChiefCloudError.refused(status: reply.status, code: code, message: error["message"] as? String ?? code)
        }
        guard (200..<300).contains(reply.status), let object else {
            // The status stays in `status` and the code (`description`, for logs), never the person's text.
            throw ChiefCloudError.refused(status: reply.status, code: "http_\(reply.status)",
                                          message: "The Cloud service isn't available right now. Try again in a moment.")
        }
        if object["ok"] as? Bool == false {
            throw ChiefCloudError.refused(status: reply.status, code: "refused", message: "the service refused the request")
        }
        return object["value"]
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

enum ChiefCloudError: Error, CustomStringConvertible {
    case refused(status: Int, code: String, message: String)
    case badReply(String)

    var description: String {
        switch self {
        case let .refused(_, code, message): "\(code): \(message)"
        case let .badReply(what): what
        }
    }

    /// The service's own words (no code), for the user.
    var message: String {
        switch self {
        case let .refused(_, _, message): message
        case let .badReply(what): what
        }
    }

    var status: Int? {
        if case let .refused(status, _, _) = self { return status }
        return nil
    }
}
