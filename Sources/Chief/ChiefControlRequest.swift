import Foundation

/// One `chief.*` socket request, parsed and validated before anything runs.
///
/// Parsing is pure (no app state), so the socket worker validates every
/// request off the main actor and tests pin the wire format.
enum ChiefControlRequest: Equatable, Sendable {
    /// `chief.open`: shows Chief Home in the target window (explicit focus intent).
    case open(target: ChiefControlWindowTarget)
    /// `chief.send`: as the user (no `from`), or as an agent report.
    case send(text: String, conversation: String?, from: String?, startTurn: Bool)
    /// `chief.status`: working conversations, unread, harness and model, home path.
    case status
    /// `chief.conversations`: every Chief conversation.
    case conversations
    /// `chief.read`: the newest `limit` messages of one conversation.
    case read(conversation: String?, limit: Int)
    /// `chief.stop`: stops the running turn of one conversation.
    case stop(conversation: String?)
    /// `chief.debug` (DEBUG builds): drives the shown transcript for automation.
    case debug(ChiefControlDebugAction, conversation: String?)

    /// Every method of the family; `chief.debug` answers only in DEBUG builds.
    static let methods: [String] = [
        "chief.open", "chief.send", "chief.status", "chief.conversations", "chief.read", "chief.stop", "chief.debug",
    ]

    static let defaultReadLimit = 20
    static let maxReadLimit = 200
    static let maxTextBytes = 65_536
    static let maxNameLength = 60
    static let maxConversationIDLength = 200

    /// Parses `params` of `method`.
    ///
    /// - Returns: The request, or the first invalid parameter.
    static func parse(method: String, params: [String: Any]) -> Result<ChiefControlRequest, ChiefControlParamError> {
        do {
            return .success(try parseOrThrow(method: method, params: params))
        } catch let error as ChiefControlParamError {
            return .failure(error)
        } catch {
            return .failure(.unknownMethod(method))
        }
    }

    private static func parseOrThrow(method: String, params: [String: Any]) throws -> ChiefControlRequest {
        switch method {
        case "chief.open":
            return .open(target: ChiefControlWindowTarget(windowID: try optionalString(params, "window_id", maxLength: 200),
                                                          workspaceID: try optionalString(params, "workspace_id", maxLength: 200)))
        case "chief.send":
            guard let raw = params["text"] as? String else { throw ChiefControlParamError.missing("text") }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ChiefControlParamError.invalid("text") }
            guard text.utf8.count <= maxTextBytes else { throw ChiefControlParamError.tooLong("text") }
            let from = try optionalString(params, "from", maxLength: maxNameLength)
            let startTurn = try optionalBool(params, "start_turn") ?? true
            return .send(text: text, conversation: try conversation(params), from: from, startTurn: startTurn)
        case "chief.status":
            return .status
        case "chief.conversations":
            return .conversations
        case "chief.read":
            let limit = try optionalInt(params, "limit") ?? defaultReadLimit
            guard limit >= 1 else { throw ChiefControlParamError.invalid("limit") }
            return .read(conversation: try conversation(params), limit: min(limit, maxReadLimit))
        case "chief.stop":
            return .stop(conversation: try conversation(params))
        case "chief.debug":
            guard let name = try optionalString(params, "action", maxLength: 64) else {
                throw ChiefControlParamError.missing("action")
            }
            let action: ChiefControlDebugAction
            switch name.lowercased() {
            case "tapback": action = .tapback(mine: try optionalBool(params, "mine") ?? false)
            case "geometry": action = .geometry
            case "rows": action = .rows
            case "messages": action = .messages(limit: max(1, min(try optionalInt(params, "limit") ?? 10, maxReadLimit)))
            case "scroll":
                guard let dy = try optionalDouble(params, "dy") else { throw ChiefControlParamError.missing("dy") }
                action = .scroll(dy: dy)
            case "set_draft", "set-draft":
                guard let text = params["text"] as? String else { throw ChiefControlParamError.missing("text") }
                guard text.utf8.count <= maxTextBytes else { throw ChiefControlParamError.tooLong("text") }
                action = .setDraft(text)
            case "send_draft", "send-draft": action = .sendDraft
            case "theme": action = .theme
            default: throw ChiefControlParamError.invalid("action")
            }
            return .debug(action, conversation: try conversation(params))
        default:
            throw ChiefControlParamError.unknownMethod(method)
        }
    }

    private static func conversation(_ params: [String: Any]) throws -> String? {
        try optionalString(params, "conversation", maxLength: maxConversationIDLength)
    }

    /// A trimmed non-empty string, nil when absent or null.
    private static func optionalString(_ params: [String: Any], _ key: String, maxLength: Int) throws -> String? {
        guard let value = params[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw ChiefControlParamError.invalid(key) }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChiefControlParamError.invalid(key) }
        guard trimmed.count <= maxLength else { throw ChiefControlParamError.tooLong(key) }
        return trimmed
    }

    private static func optionalBool(_ params: [String: Any], _ key: String) throws -> Bool? {
        guard let value = params[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if let bool = value as? Bool { return bool }
        throw ChiefControlParamError.invalid(key)
    }

    private static func optionalInt(_ params: [String: Any], _ key: String) throws -> Int? {
        guard let value = params[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            guard double.rounded() == double, abs(double) < 1_000_000 else { throw ChiefControlParamError.invalid(key) }
            return Int(double)
        }
        if let string = value as? String, let int = Int(string.trimmingCharacters(in: .whitespaces)) { return int }
        throw ChiefControlParamError.invalid(key)
    }

    private static func optionalDouble(_ params: [String: Any], _ key: String) throws -> Double? {
        guard let value = params[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return number.doubleValue
        }
        if let string = value as? String, let double = Double(string.trimmingCharacters(in: .whitespaces)), double.isFinite {
            return double
        }
        throw ChiefControlParamError.invalid(key)
    }
}

/// Which window `chief.open` shows Home in: `window_id` wins, then the
/// window that owns `workspace_id` (the caller's), then the active window.
struct ChiefControlWindowTarget: Equatable, Sendable {
    var windowID: String?
    var workspaceID: String?
}

/// `chief.debug` actions over `MessagesLabHomeView`'s `debug*` helpers.
enum ChiefControlDebugAction: Equatable, Sendable {
    /// A love tapback on the newest incoming message (or, with `mine`, my newest).
    case tapback(mine: Bool)
    /// The transcript's geometry (`debugGeometry`).
    case geometry
    /// Every visible row's frame (`debugRowFrames`).
    case rows
    /// The newest message texts as shown (`debugMessageTexts`).
    case messages(limit: Int)
    /// Scrolls the transcript by `dy` points.
    case scroll(dy: Double)
    /// Puts text in the compose field.
    case setDraft(String)
    /// Presses Return in the compose field.
    case sendDraft
    /// The Chief theme the transcript draws with.
    case theme
}

/// Why a `chief.*` request was refused before it ran.
enum ChiefControlParamError: Error, Equatable, Sendable {
    case missing(String)
    case invalid(String)
    case tooLong(String)
    case unknownMethod(String)

    /// The parameter name, nil for an unknown method.
    var parameter: String? {
        switch self {
        case .missing(let key), .invalid(let key), .tooLong(let key): key
        case .unknownMethod: nil
        }
    }

    /// The socket error message.
    var message: String {
        switch self {
        case .missing(let key):
            String(format: String(localized: "socket.chief.error.missingParam",
                                  defaultValue: "Missing parameter: %@"), key)
        case .invalid(let key):
            String(format: String(localized: "socket.chief.error.invalidParam",
                                  defaultValue: "Invalid parameter: %@"), key)
        case .tooLong(let key):
            String(format: String(localized: "socket.chief.error.paramTooLong",
                                  defaultValue: "Parameter is too long: %@"), key)
        case .unknownMethod:
            String(localized: "socket.error.unknownMethod", defaultValue: "Unknown method")
        }
    }
}
