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

/// Where the Cloud service is: `CmuxMobileCloudAPIBase` in Info.plist (project.yml
/// `CMUX_MOBILE_CLOUD_API_BASE`), or the `CMUX_MOBILE_CLOUD_API_BASE` launch override in
/// DEBUG builds. Empty: this build has no Cloud Chief.
public struct ChiefCloudConfig: Sendable, Equatable {
    public var baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               bundle: Bundle = .main) -> ChiefCloudConfig? {
        #if DEBUG
        if let raw = environment["CMUX_MOBILE_CLOUD_API_BASE"] {
            return URL(string: raw).flatMap { $0.host() == nil ? nil : ChiefCloudConfig(baseURL: $0) }
        }
        #endif
        guard let raw = bundle.object(forInfoDictionaryKey: "CmuxMobileCloudAPIBase") as? String, !raw.isEmpty,
              let url = URL(string: raw), url.host() != nil else { return nil }
        return ChiefCloudConfig(baseURL: url)
    }
}

/// The Cloud service as the signed-in user: the bearer is the account's
/// access token (`authorization: Bearer`), refreshed once after a 401.
/// Bodies and replies are bytes, so callers parse them in their own isolation.
struct ChiefCloudHTTP: Sendable {
    let base: URL
    let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    var session: URLSession = .shared

    struct Reply: Sendable {
        var status: Int
        var body: Data
    }

    func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)?.absoluteURL ?? base.appendingPathComponent(path)
    }

    /// `method path` with the bearer; one retry with a fresh token after a 401.
    func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Reply {
        var forceRefresh = false
        while true {
            let token = try await accessToken(forceRefresh)
            var request = URLRequest(url: url(path))
            request.httpMethod = method
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.httpBody = body
            }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !forceRefresh {
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
            throw ChiefCloudError.refused(status: reply.status, code: "http_\(reply.status)", message: "HTTP \(reply.status)")
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
