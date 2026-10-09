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
    }

    /// One recent turn's end, as the brain summarizes its trace.
    public struct Turn: Decodable, Sendable, Equatable {
        public var harness: String?
        public var model: String?
        public var status: String?
        public var ms: Double?
        public var tools: Int?
        public var toolErrors: Int?
        public var costUSD: Double?
        public var usage: Usage?
        public var reply: String?

        public struct Usage: Decodable, Sendable, Equatable {
            public var cacheRead: Double?
            public var cacheWrite: Double?
            public var input: Double?

            enum CodingKeys: String, CodingKey {
                case input
                case cacheRead = "cache_read"
                case cacheWrite = "cache_write"
            }
        }

        enum CodingKeys: String, CodingKey {
            case harness, model, status, ms, tools, usage, reply
            case toolErrors = "tool_errors"
            case costUSD = "cost_usd"
        }
    }

    /// What the turns run on (engine.json over the brain's defaults).
    public var engine: Engine
    /// engine.json as saved: the fields the owner chose.
    public var choice: Engine
    /// The newest turn ends, newest first.
    public var recent: [Turn]

    enum CodingKeys: String, CodingKey { case engine, choice, recent }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(Engine.self, forKey: .engine)
        choice = try c.decodeIfPresent(Engine.self, forKey: .choice) ?? Engine()
        recent = try c.decodeIfPresent([Turn].self, forKey: .recent) ?? []
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

extension DaemonConnection {
    /// `chief.engine.get`: the brain's engine report.
    public func chiefEngine() async throws(ChiefControlError) -> ChiefEngineReport {
        do {
            return try await resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.engine.get", params: [:])
            }, as: ChiefEngineReport.self)
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.engine.set`: absent fields stay, "default" clears one; the
    /// report after the write.
    public func setChiefEngine(harness: String? = nil, model: String? = nil,
                               effort: String? = nil) async throws(ChiefControlError) -> ChiefEngineReport {
        var params: [String: JSONValue] = [:]
        for (key, value) in [("harness", harness), ("model", model), ("effort", effort)] {
            if let value { params[key] = .string(value) }
        }
        let key = "cmux-next-chief-engine-" + UUID().uuidString.lowercased()
        let fields = params
        do {
            return try await resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.engine.set", params: fields, idempotencyKey: key)
            }, as: ResourceMutationResult<ChiefEngineReport>.self).value
        } catch {
            throw ChiefControlError(error)
        }
    }

    /// `chief.stop`: true when a running turn was stopped.
    public func stopChief() async throws(ChiefControlError) -> Bool {
        struct Stopped: Decodable, Sendable { var stopped: Bool }
        let key = "cmux-next-chief-stop-" + UUID().uuidString.lowercased()
        do {
            return try await resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "chief.stop", params: [:], idempotencyKey: key)
            }, as: ResourceMutationResult<Stopped>.self).value.stopped
        } catch {
            throw ChiefControlError(error)
        }
    }
}
