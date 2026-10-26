public import Foundation

/// The owner's control of a Chief brain (cmux-tui resource-operations-v2.json
/// `chief.engine.get`, `chief.engine.set`, `chief.stop`): the daemon forwards
/// each to the brain host's tools socket (`CMUX_TUI_CHIEF_TOOLS_SOCKET`) and
/// answers only the owner's trusted connection (a local client, or the link's
/// owner_session splice to a paired server's daemon).
public struct ChiefEngineReport: Decodable, Sendable, Equatable {
    /// The engine fields; nil is the brain's default.
    public struct Engine: Decodable, Sendable, Equatable {
        public var harness: String?
        public var model: String?
        public var effort: String?
        /// `fast` (the harness's priority tier), else nil or `default`: the harness's own.
        public var speed: String?
        /// The reaction classifier (a416): its harness, model and instructions ("" in `engine`: the
        /// host's Claude route, the built-in prompt), and whether a tapback may wake the Chief. In
        /// `engine` the brain's resolution (engine.json over cmux.json); in `choice` this Chief's own.
        /// Nil from an older brain.
        public var classifierHarness: String?
        public var classifierModel: String?
        public var classifierPrompt: String?
        public var reactionsCanWake: Bool?

        public init(harness: String? = nil, model: String? = nil, effort: String? = nil, speed: String? = nil) {
            self.harness = harness
            self.model = model
            self.effort = effort
            self.speed = speed
        }

        enum CodingKeys: String, CodingKey {
            case harness, model, effort, speed
            case classifierHarness = "classifier_harness", classifierModel = "classifier_model"
            case classifierPrompt = "classifier_prompt", reactionsCanWake = "reactions_can_wake"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            harness = try c.decodeIfPresent(String.self, forKey: .harness)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            effort = try c.decodeIfPresent(String.self, forKey: .effort)
            speed = try c.decodeIfPresent(String.self, forKey: .speed)
            classifierHarness = try c.decodeIfPresent(String.self, forKey: .classifierHarness)
            classifierModel = try c.decodeIfPresent(String.self, forKey: .classifierModel)
            classifierPrompt = try c.decodeIfPresent(String.self, forKey: .classifierPrompt)
            // engine.json may keep it as the string a set sent ("true"/"false").
            if let on = try? c.decodeIfPresent(Bool.self, forKey: .reactionsCanWake) {
                reactionsCanWake = on
            } else {
                reactionsCanWake = (try? c.decodeIfPresent(String.self, forKey: .reactionsCanWake)).flatMap { $0.flatMap(Bool.init) }
            }
        }
    }

    /// One recent turn's end, as the brain summarizes its trace.
    /// Every field is optional (decoded only when present), so an older brain's summary, which
    /// lacks `ts`, `effort`, `error` and the usage's `output`, still decodes.
    public struct Turn: Decodable, Sendable, Equatable {
        public var harness: String?
        public var model: String?
        /// The effort the turn ran at (`high`), nil when the harness has none or the brain is older.
        public var effort: String?
        public var status: String?
        /// When the turn ended, in milliseconds since 1970.
        public var ts: Double?
        public var ms: Double?
        public var tools: Int?
        public var toolErrors: Int?
        public var costUSD: Double?
        public var usage: Usage?
        public var reply: String?
        /// The first characters of the error a failed turn ended with.
        public var error: String?

        public struct Usage: Decodable, Sendable, Equatable {
            public var cacheRead: Double?
            public var cacheWrite: Double?
            public var input: Double?
            public var output: Double?

            enum CodingKeys: String, CodingKey {
                case input, output
                case cacheRead = "cache_read"
                case cacheWrite = "cache_write"
            }
        }

        enum CodingKeys: String, CodingKey {
            case harness, model, effort, status, ts, ms, tools, usage, reply, error
            case toolErrors = "tool_errors"
            case costUSD = "cost_usd"
        }
    }

    /// A model acpmux offers for the engine's harness, with the catalog metadata acpmux attached
    /// (nil from an older brain, or for a model the catalog does not describe).
    public struct Model: Decodable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// The catalog family ("Opus", "Sol"), or the provider for a gateway's models.
        public var family: String?
        public var provider: String?
        /// The name without the vendor word ("Opus 5.5").
        public var shortName: String?
        /// The efforts the model takes, in order; nil when the catalog does not say.
        public var efforts: [String]?
        public var defaultEffort: String?
        /// Whether the model runs the fast tier; nil when the catalog does not say.
        public var fast: Bool?
        /// The harness aliases that run this release (`opus` for Claude Opus 5.5).
        public var aliases: [String]?
        /// The release an alias runs, as the harness reported it (Claude Code's `resolvedModel`).
        public var resolvedModel: String?
        public var contextWindow: Int?
        /// The release date (`YYYY-MM-DD`), which orders a family's versions.
        public var releaseDate: String?
        public var description: String?

        public init(id: String, name: String, family: String? = nil, provider: String? = nil, shortName: String? = nil,
                    efforts: [String]? = nil, defaultEffort: String? = nil, fast: Bool? = nil, aliases: [String]? = nil,
                    resolvedModel: String? = nil, contextWindow: Int? = nil, releaseDate: String? = nil,
                    description: String? = nil) {
            self.id = id
            self.name = name
            self.family = family
            self.provider = provider
            self.shortName = shortName
            self.efforts = efforts
            self.defaultEffort = defaultEffort
            self.fast = fast
            self.aliases = aliases
            self.resolvedModel = resolvedModel
            self.contextWindow = contextWindow
            self.releaseDate = releaseDate
            self.description = description
        }
    }

    /// What a set may pick: acpmux's models for the engine's harness, the
    /// efforts the brain takes and the speeds the turns' harness runs (each
    /// empty from an older brain).
    public struct Offered: Decodable, Sendable, Equatable {
        public var models: [Model] = []
        public var efforts: [String] = []
        public var speeds: [String] = []

        public init(models: [Model] = [], efforts: [String] = [], speeds: [String] = []) {
            self.models = models
            self.efforts = efforts
            self.speeds = speeds
        }

        enum CodingKeys: String, CodingKey { case models, efforts, speeds }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            models = try c.decodeIfPresent([Model].self, forKey: .models) ?? []
            efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
            speeds = try c.decodeIfPresent([String].self, forKey: .speeds) ?? []
        }
    }

    /// What the turns run on (engine.json over the brain's defaults).
    public var engine: Engine
    /// engine.json as saved: the fields the owner chose.
    public var choice: Engine
    /// The newest turn ends, newest first.
    public var recent: [Turn]
    public var offered: Offered

    enum CodingKeys: String, CodingKey { case engine, choice, recent, offered }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(Engine.self, forKey: .engine)
        choice = try c.decodeIfPresent(Engine.self, forKey: .choice) ?? Engine()
        recent = try c.decodeIfPresent([Turn].self, forKey: .recent) ?? []
        offered = try c.decodeIfPresent(Offered.self, forKey: .offered) ?? Offered()
    }
}

/// Why a Chief control op failed, one case per thing the user can be told.
public enum ChiefControlError: Error, Sendable, Equatable {
    /// No connection to the daemon in front of the brain, or the daemon
    /// could not reach the brain (`operation.failed` reason `unavailable`).
    case unreachable
    /// The daemon refused this connection (`origin.forbidden`).
    case forbidden
    /// The daemon has no brain tools socket (reason `not_configured`).
    case notConfigured
    /// The daemon does not know the operation (an older cmux-tui).
    case unsupported
    /// The brain refused (reason `unknown_harness`, `invalid_effort`, ...).
    case refused(reason: String, message: String)
    case other(String)

    public init(_ error: any Error) {
        switch error as? DaemonError {
        case .notConnected?, .connectionClosed?, .daemonShutdown?, .connectFailed?, .timedOut?, .endpointBlocked?:
            self = .unreachable
        case .command(_, let message, let code, let details, _)?:
            switch code {
            case "origin.forbidden": self = .forbidden
            case "validation.invalid": self = .unsupported
            case "operation.failed":
                let reason = details?["reason"]?.stringValue ?? ""
                let text = details?["extra"]?["message"]?.stringValue ?? message
                switch reason {
                case "not_configured": self = .notConfigured
                case "unavailable": self = .unreachable
                default: self = .refused(reason: reason, message: text)
                }
            default: self = .other(message)
            }
        default:
            self = .other(String(describing: error))
        }
    }
}

/// `chief.engine.get` / `chief.engine.set` / `chief.stop` /
/// `chief.automation.list|update` on one daemon connection. Its own type,
/// not a `DaemonConnection` extension (that type's line budget is frozen).
public struct ChiefControlClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// `chief.engine.get`: the brain's engine report. `chief` names a Chief
    /// that is not the default (chief-brains-v1); nil: the default Chief.
    public func chiefEngine(chief: String? = nil) async throws(ChiefControlError) -> ChiefEngineReport {
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.engine.get", params: Self.naming(chief, [:]))
            }, as: ChiefEngineReport.self)
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.engine.set`: absent fields stay, "default" clears one; the
    /// report after the write. `chief` as in `chiefEngine(chief:)`.
    public func setChiefEngine(harness: String? = nil, model: String? = nil, effort: String? = nil,
                               speed: String? = nil, chief: String? = nil) async throws(ChiefControlError) -> ChiefEngineReport {
        let fields = [("harness", harness), ("model", model), ("effort", effort), ("speed", speed)]
        return try await setChiefEngine(Dictionary(uniqueKeysWithValues: fields.compactMap { key, value in value.map { (key, $0) } }), chief: chief)
    }

    /// The fields `chief.engine.set` takes: the turns' engine, and the reaction classifier (a416).
    public static let engineSetKeys: Set<String> = ["harness", "model", "effort", "speed", "classifier_harness",
                                                    "classifier_model", "classifier_prompt", "reactions_can_wake"]

    /// `params` of a `chief.engine.set` of `fields` (only ``engineSetKeys``; "default" clears one).
    static func engineSetParams(_ fields: [String: String], chief: String?) -> [String: JSONValue] {
        naming(chief, fields.filter { engineSetKeys.contains($0.key) }.mapValues(JSONValue.string))
    }

    /// `chief.engine.set` of any ``engineSetKeys`` fields: absent ones stay, "default" clears one.
    public func setChiefEngine(_ fields: [String: String], chief: String? = nil) async throws(ChiefControlError) -> ChiefEngineReport {
        let params = Self.engineSetParams(fields, chief: chief)
        let key = "cmux-next-chief-engine-" + UUID().uuidString.lowercased()
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.engine.set", params: params, idempotencyKey: key)
            }, as: ResourceMutationResult<ChiefEngineReport>.self).value
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.stop`: true when a running turn was stopped. `chief` as in
    /// `chiefEngine(chief:)`.
    public func stopChief(chief: String? = nil) async throws(ChiefControlError) -> Bool {
        struct Stopped: Decodable, Sendable { var stopped: Bool }
        let key = "cmux-next-chief-stop-" + UUID().uuidString.lowercased()
        let params = Self.naming(chief, [:])
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.stop", params: params, idempotencyKey: key)
            }, as: ResourceMutationResult<Stopped>.self).value.stopped
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.stop {all: true}` (Stop all agents): the running turn and every
    /// subagent at work or queued stop; the answer names the subagents (the
    /// undo toast's list and its Restart). `chief` as in `chiefEngine(chief:)`.
    public func stopAllAgents(chief: String? = nil) async throws(ChiefControlError) -> ChiefStopAll {
        let key = "cmux-next-chief-stop-all-" + UUID().uuidString.lowercased()
        let params = Self.naming(chief, ["all": .bool(true)])
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.stop", params: params, idempotencyKey: key)
            }, as: ResourceMutationResult<ChiefStopAll>.self).value
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.stop {restart: [ids]}` (Restart on the stop-all toast): those
    /// subagents go on; nothing stops. `chief` as in `chiefEngine(chief:)`.
    public func restartAgents(_ names: [String], chief: String? = nil) async throws(ChiefControlError) -> ChiefRestart {
        let key = "cmux-next-chief-restart-" + UUID().uuidString.lowercased()
        let params = Self.naming(chief, ["restart": .array(names.map(JSONValue.string))])
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.stop", params: params, idempotencyKey: key)
            }, as: ResourceMutationResult<ChiefRestart>.self).value
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.automation.list`: the Chief's automations, oldest first (issue 25573). `chief` as
    /// in `chiefEngine(chief:)`.
    public func chiefAutomations(chief: String? = nil) async throws(ChiefControlError) -> [ChiefAutomation] {
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.automation.list", params: Self.naming(chief, [:]))
            }, as: ChiefAutomationList.self).automations
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.automation.update`: pauses, resumes, deletes or runs automation `id` now; the
    /// list after the change. `chief` as in `chiefEngine(chief:)`.
    public func updateChiefAutomation(_ id: String, _ action: ChiefAutomationAction,
                                      chief: String? = nil) async throws(ChiefControlError) -> [ChiefAutomation] {
        let key = "cmux-next-chief-automation-" + UUID().uuidString.lowercased()
        let params = Self.naming(chief, ["automation": .string(id), "action": .string(action.rawValue)])
        do {
            return try await connection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.automation.update", params: params, idempotencyKey: key)
            }, as: ResourceMutationResult<ChiefAutomationList>.self).value.automations
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `params` with the `chief` field when `chief` names a Chief.
    static func naming(_ chief: String?, _ params: [String: JSONValue]) -> [String: JSONValue] {
        guard let chief, !chief.isEmpty else { return params }
        return params.merging(["chief": .string(chief)]) { _, named in named }
    }
}
