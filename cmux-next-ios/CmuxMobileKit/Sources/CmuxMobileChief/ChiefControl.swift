import CmuxMobileTransport
import Foundation

/// The brain's engine report (`chief.engine.get`, cmux-tui
/// resource-api-v2.md "Chief control"): the same fields the Mac's Chief
/// settings read (`ChiefEngineReport` in CmuxNextDaemon).
public struct ChiefEngineReport: Codable, Sendable, Equatable {
    public struct Engine: Codable, Sendable, Equatable {
        public var harness: String?
        /// The model turns run. On a Mac with #20531 it is resolved: the
        /// chosen model, else what the default resolves to
        /// (`modelIsDefault`); older Macs send only the chosen one.
        public var model: String?
        public var effort: String?
        /// True when `model` is what the default resolves to; nil from an
        /// older Mac, which does not say.
        public var modelIsDefault: Bool?

        public init(harness: String? = nil, model: String? = nil, effort: String? = nil, modelIsDefault: Bool? = nil) {
            self.harness = harness
            self.model = model
            self.effort = effort
            self.modelIsDefault = modelIsDefault
        }

        enum CodingKeys: String, CodingKey {
            case harness, model, effort
            case modelIsDefault = "model_is_default"
        }
    }

    public struct Turn: Codable, Sendable, Equatable {
        public var harness: String?
        public var model: String?
        public var status: String?
        public var ms: Double?
        public var tools: Int?
        public var costUSD: Double?
        public var reply: String?

        enum CodingKeys: String, CodingKey {
            case harness, model, status, ms, tools, reply
            case costUSD = "cost_usd"
        }
    }

    public struct Model: Codable, Sendable, Equatable, Hashable {
        public var id: String
        public var name: String
        /// On acpmux's "default" entry (#20531): the model id it resolves to.
        public var resolvesTo: String?

        public init(id: String, name: String, resolvesTo: String? = nil) {
            self.id = id
            self.name = name
            self.resolvesTo = resolvesTo
        }

        enum CodingKeys: String, CodingKey {
            case id, name
            case resolvesTo = "resolves_to"
        }
    }

    public struct Offered: Codable, Sendable, Equatable {
        public var models: [Model] = []
        public var efforts: [String] = []
        /// What the default resolves to (#20531), {id, name}; nil when the
        /// Mac does not know or is older.
        public var defaultModel: Model?

        public init(models: [Model] = [], efforts: [String] = [], defaultModel: Model? = nil) {
            self.models = models
            self.efforts = efforts
            self.defaultModel = defaultModel
        }

        enum CodingKeys: String, CodingKey {
            case models, efforts
            case defaultModel = "default_model"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            models = try c.decodeIfPresent([Model].self, forKey: .models) ?? []
            efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
            defaultModel = try? c.decodeIfPresent(Model.self, forKey: .defaultModel)
        }
    }

    /// What turns run on (the saved choice over the brain's defaults).
    public var engine: Engine
    /// What the owner chose; nil fields follow the brain's default.
    public var choice: Engine
    /// The newest turn ends, newest first.
    public var recent: [Turn]
    public var offered: Offered
    /// Chief's avatar text from the Mac's `optchat/profile.json`, when the
    /// Mac's reply carries an `avatar` key (`avatarSupported`); nil or empty
    /// is the default, "C". A picture's file name is not avatar text.
    public var avatar: String?
    /// Whether this Mac reads and sets the avatar (`chief.engine.get` has an
    /// `avatar` key, `chief.engine.set` takes one). Older Macs do not.
    public var avatarSupported: Bool

    enum CodingKeys: String, CodingKey { case engine, choice, recent, offered, avatar }

    public init(engine: Engine, choice: Engine = Engine(), recent: [Turn] = [], offered: Offered = Offered(),
                avatar: String? = nil, avatarSupported: Bool = false) {
        self.engine = engine
        self.choice = choice
        self.recent = recent
        self.offered = offered
        self.avatar = avatar
        self.avatarSupported = avatarSupported
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(Engine.self, forKey: .engine)
        choice = try c.decodeIfPresent(Engine.self, forKey: .choice) ?? Engine()
        recent = try c.decodeIfPresent([Turn].self, forKey: .recent) ?? []
        offered = try c.decodeIfPresent(Offered.self, forKey: .offered) ?? Offered()
        avatarSupported = c.contains(.avatar)
        // A non-string avatar (a newer picture object) reads as none.
        avatar = Self.avatarText((try? c.decodeIfPresent(String.self, forKey: .avatar)) ?? nil)
    }

    /// The Mac's shape, so a report kept on this phone (``ChiefPreferences``)
    /// decodes back the same: `avatar` only when the Mac sent one.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(engine, forKey: .engine)
        try c.encode(choice, forKey: .choice)
        try c.encode(recent, forKey: .recent)
        try c.encode(offered, forKey: .offered)
        if avatarSupported { try c.encode(avatar ?? "", forKey: .avatar) }
    }

    /// Avatar text as Chief is drawn: trimmed, at most two characters, and
    /// never a picture's file name (`cat.png`); nil when there is none.
    public static func avatarText(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Defensive (F7): a Mac before #20531 could send profile.json's
        // picture name; anything that looks like a file or a path is not text.
        if text.contains("/") || text.contains("\\") { return nil }
        let pictureExtensions = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg"]
        if pictureExtensions.contains((text as NSString).pathExtension.lowercased()) { return nil }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return nil }
        return String(text.prefix(2))
    }

    /// acpmux's own "default" model entry; on a #20531 Mac it is named after
    /// what it resolves to ("Default (GPT-6.1 Sol)", `resolvesTo`).
    public var defaultEntry: Model? { offered.models.first { $0.id == "default" } }

    /// The display name of the model the default resolves to, from a Mac
    /// that resolves it (#20531): `offered.default_model`, else the default
    /// entry's `resolves_to`, else `engine.model` with `model_is_default`.
    /// nil from an older Mac, which shows plain "Default".
    public var resolvedDefaultName: String? {
        if let model = offered.defaultModel {
            return model.name.isEmpty ? modelName(model.id) ?? model.id : model.name
        }
        if let id = defaultEntry?.resolvesTo, !id.isEmpty { return modelName(id) ?? id }
        if engine.modelIsDefault == true, let id = engine.model, id != "default" { return modelName(id) ?? id }
        return nil
    }

    /// The models to pick, without acpmux's "default" entry.
    public var pickableModels: [Model] { offered.models.filter { $0.id != "default" } }

    /// A model id's display name, from what the Mac offers.
    public func modelName(_ id: String?) -> String? {
        guard let id, id != "default" else { return nil }
        return offered.models.first { $0.id == id }?.name
    }

    /// The harnesses the Mac's picker offers (HomeChiefSidebar): Claude and
    /// Codex, plus the current one when it is another (a CodeRouter route).
    public var harnesses: [String] {
        var list = ["claude", "codex"]
        if let current = engine.harness, !list.contains(current) { list.append(current) }
        return list
    }
}

/// Why a Chief control request failed, in words the settings page shows.
public struct ChiefControlError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var reason: String?
    public var message: String

    public var description: String {
        switch (code, reason) {
        case ("origin.forbidden", _): return String(localized: "This Mac does not let a phone change Chief.")
        case (_, "not_configured"?): return String(localized: "Chief isn't running on this Mac. Open Home in cmux on the Mac to start it.")
        case (_, "unavailable"?): return String(localized: "Chief isn't answering on this Mac.")
        default: return message.isEmpty ? code : message
        }
    }
}

/// `chief.engine.get`, `chief.engine.set` and `chief.stop` over the phone's
/// `chief` channel: the Mac's ChiefControlClient requests, carried by
/// cmux-mobile-host's Chief policy to the Chief owner, which forwards them to the
/// brain (the only writer of its engine file).
public struct ChiefControl: Sendable {
    let client: DaemonClient
    let clock: any Clock<Duration>

    /// How long the phone waits for an answer. The Mac's daemon gives
    /// Chief 10 s (cmux-tui `chief_control.rs` `TIMEOUT`) and then answers
    /// `unavailable` itself, so a live Mac always answers first; only a link
    /// that went quiet reaches this, and the page says the Mac didn't answer.
    public static let replyDeadline: Duration = .seconds(20)

    public init(client: DaemonClient, clock: any Clock<Duration> = ContinuousClock()) {
        self.client = client
        self.clock = clock
    }

    public func engine() async throws -> ChiefEngineReport {
        try await request("chief.engine.get", mutation: false)
    }

    /// Absent fields stay; "default" clears one (as on the Mac).
    /// `avatar` is sent only to a Mac whose report has `avatarSupported`.
    public func setEngine(harness: String? = nil, model: String? = nil, effort: String? = nil,
                          avatar: String? = nil) async throws -> ChiefEngineReport {
        var params: [String: Any] = [:]
        if let harness { params["harness"] = harness }
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        if let avatar { params["avatar"] = avatar }
        return try await request("chief.engine.set", params: params, mutation: true,
                                 key: "cmux-next-ios-chief-engine-" + UUID().uuidString.lowercased())
    }

    /// True when a running turn was stopped.
    public func stop() async throws -> Bool {
        struct Stopped: Decodable { var stopped: Bool }
        let result: Stopped = try await request("chief.stop", mutation: true, key: "cmux-next-ios-chief-stop-" + UUID().uuidString.lowercased())
        return result.stopped
    }

    private func request<T: Decodable>(_ operation: String, params: sending [String: Any] = [:], mutation: Bool, key: String? = nil) async throws -> T {
        let line = try await client.resourceRequest(operation, params: params, idempotencyKey: key,
                                                    deadline: Self.replyDeadline, clock: clock)
        return try Self.decode(line, mutation: mutation)
    }

    /// A v2 response: `result` (a mutation's under `value`), or the error.
    static func decode<T: Decodable>(_ line: Data, mutation: Bool) throws -> T {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ChiefControlError(code: "malformed", reason: nil, message: "bad Chief control reply")
        }
        if object["ok"] as? Bool != true {
            let error = object["error"] as? [String: Any] ?? [:]
            let details = error["details"] as? [String: Any]
            let extra = (details?["extra"] as? [String: Any])?["message"] as? String ?? details?["message"] as? String
            // A v12 refusal (an older host) carries `error` as text.
            let text = error["message"] as? String ?? object["error"] as? String ?? ""
            throw ChiefControlError(code: error["code"] as? String ?? object["error_code"] as? String ?? "failed",
                                    reason: details?["reason"] as? String, message: extra ?? text)
        }
        var result = object["result"]
        if mutation { result = (result as? [String: Any])?["value"] }
        let data = try JSONSerialization.data(withJSONObject: result ?? [:])
        return try JSONDecoder().decode(T.self, from: data)
    }
}
