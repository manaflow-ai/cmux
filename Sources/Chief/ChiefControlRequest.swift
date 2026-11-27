import Foundation

/// One `chief.*` socket request, parsed and validated before anything runs.
///
/// Parsing is pure (no app state), so the socket worker validates every
/// request off the main actor and tests pin the wire format.
enum ChiefControlRequest: Equatable, Sendable {
    /// `chief.open`: shows Chief Home in the target window (explicit focus intent).
    case open(target: ChiefControlWindowTarget)
    /// `chief.send`: as the user (no `from`), or as an agent report.
    case send(text: String, conversation: String?, from: String?, startTurn: Bool, clientMessageID: String?)
    /// `chief.status`: working conversations, unread, harness and model, home path.
    case status
    /// `chief.conversations`: every Chief conversation.
    case conversations
    /// `chief.conversations` waiting for a change to the last snapshot.
    case conversationsAfter(cursor: String)
    /// `chief.read`: the newest `limit` messages, or a page before `beforeSeq`.
    case read(conversation: String?, beforeSeq: UInt64?, limit: Int)
    /// `chief.read` waiting on the owner's event stream until the conversation
    /// changes after `afterSeq`. This keeps mobile refreshes event-driven.
    case readAfter(conversation: String?, afterSeq: UInt64, limit: Int, afterCursor: String? = nil)
    /// `chief.mark_read`: advances the signed-in user's read cursor.
    case markRead(conversation: String?, upToSeq: UInt64)
    /// `chief.stop`: stops the running turn of one conversation.
    case stop(conversation: String?)
    /// `chief.approve`: answers an approval card (`request` nil: the running turn's newest waiting one) with
    /// one of its options (`choice`, case-insensitive: "Allow", "Deny").
    case approve(conversation: String?, request: String?, choice: String)
    /// `chief.answer`: answers a question card (`message` nil: the newest waiting one) as its Submit
    /// does: `choices` name options by label or id, `text` fills an Other field; neither keeps the
    /// card's preselection.
    case answer(conversation: String?, message: String?, choices: [String], text: String?)
    /// `chief.debug` (DEBUG builds): drives the shown transcript for automation.
    case debug(ChiefControlDebugAction, conversation: String?)

    /// Every method of the family; `chief.debug` answers only in DEBUG builds.
    static let methods: [String] = [
        "chief.open", "chief.send", "chief.status", "chief.conversations", "chief.read", "chief.mark_read", "chief.stop", "chief.approve",
        "chief.answer", "chief.debug",
    ]

    /// Whether this build answers `method` from the socket. `chief.approve`,
    /// `chief.answer` and `chief.debug` answer only in DEBUG builds (automation,
    /// tours): in a release build any local socket client, the Chief's own shell
    /// included, could otherwise answer the approval cards that gate the Chief's
    /// commands and the question cards that confirm what it creates, so cards are
    /// answered only in Home there.
    static func isAvailable(_ method: String, debugBuild: Bool = isDebugBuild) -> Bool {
        debugBuild || !debugOnlyMethods.contains(method)
    }

    /// The methods ``isAvailable(_:debugBuild:)`` keeps to DEBUG builds.
    static let debugOnlyMethods: Set<String> = ["chief.approve", "chief.answer", "chief.debug"]

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    static let defaultReadLimit = 20
    static let maxReadLimit = 200
    static let maxTextBytes = 65_536
    static let maxNameLength = 60
    static let maxConversationIDLength = 200
    static let maxChoices = 20
    static let maxChoiceLength = 200

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
            guard let value = params["text"], !(value is NSNull) else { throw ChiefControlParamError.missing("text") }
            guard let raw = value as? String else { throw ChiefControlParamError.invalid("text") }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ChiefControlParamError.invalid("text") }
            guard text.utf8.count <= maxTextBytes else { throw ChiefControlParamError.tooLong("text") }
            let from = try optionalString(params, "from", maxLength: maxNameLength)
            let clientMessageID = try optionalString(params, "client_message_id", maxLength: 200)
            let startTurn = try optionalBool(params, "start_turn") ?? true
            return .send(text: text, conversation: try conversation(params), from: from, startTurn: startTurn,
                         clientMessageID: clientMessageID)
        case "chief.status":
            return .status
        case "chief.conversations":
            let cursor = try optionalString(params, "after_cursor", maxLength: 200)
            if try optionalBool(params, "wait_for_change") == true {
                guard let cursor else { throw ChiefControlParamError.missing("after_cursor") }
                return .conversationsAfter(cursor: cursor)
            }
            guard cursor == nil else { throw ChiefControlParamError.invalid("after_cursor") }
            return .conversations
        case "chief.read":
            let limit = try optionalInt(params, "limit") ?? defaultReadLimit
            guard limit >= 1 else { throw ChiefControlParamError.invalid("limit") }
            let beforeSeq = try optionalInt(params, "before_seq")
            if let beforeSeq, beforeSeq < 1 { throw ChiefControlParamError.invalid("before_seq") }
            let afterSeq = try optionalInt(params, "after_seq")
            if let afterSeq, afterSeq < 0 { throw ChiefControlParamError.invalid("after_seq") }
            let waitForChange = try optionalBool(params, "wait_for_change") ?? false
            let afterCursor = try optionalString(params, "after_cursor", maxLength: 200)
            if waitForChange {
                guard beforeSeq == nil, let afterSeq else { throw ChiefControlParamError.invalid("after_seq") }
                return .readAfter(conversation: try conversation(params), afterSeq: UInt64(afterSeq),
                                  limit: min(limit, maxReadLimit), afterCursor: afterCursor)
            }
            guard afterCursor == nil else { throw ChiefControlParamError.invalid("after_cursor") }
            guard afterSeq == nil else { throw ChiefControlParamError.invalid("after_seq") }
            return .read(conversation: try conversation(params),
                         beforeSeq: beforeSeq.map { UInt64($0) },
                         limit: min(limit, maxReadLimit))
        case "chief.mark_read":
            guard let upToSeq = try optionalInt(params, "up_to_seq") else {
                throw ChiefControlParamError.missing("up_to_seq")
            }
            guard upToSeq >= 1 else { throw ChiefControlParamError.invalid("up_to_seq") }
            return .markRead(conversation: try conversation(params), upToSeq: UInt64(upToSeq))
        case "chief.stop":
            return .stop(conversation: try conversation(params))
        case "chief.approve":
            guard let choice = try optionalString(params, "choice", maxLength: maxNameLength) else {
                throw ChiefControlParamError.missing("choice")
            }
            return .approve(conversation: try conversation(params), request: try optionalString(params, "request", maxLength: 200),
                            choice: choice)
        case "chief.answer":
            let text = try optionalString(params, "text", maxLength: maxTextBytes)
            if let text, text.utf8.count > maxTextBytes { throw ChiefControlParamError.tooLong("text") }
            return .answer(conversation: try conversation(params), message: try optionalString(params, "message", maxLength: 200),
                           choices: try choices(params), text: text)
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
            case "open_settings", "open-settings": action = .openSettings
            case "close_settings", "close-settings": action = .closeSettings
            case "open_memory", "open-memory": action = .openMemory
            case "close_memory", "close-memory": action = .closeMemory
            case "expand_tools", "expand-tools": action = .expandTools
            default: throw ChiefControlParamError.invalid("action")
            }
            return .debug(action, conversation: try conversation(params))
        default:
            throw ChiefControlParamError.unknownMethod(method)
        }
    }

    /// `choices`: an array of option names, or one string; absent or null is none.
    private static func choices(_ params: [String: Any]) throws -> [String] {
        guard let value = params["choices"], !(value is NSNull) else { return [] }
        let raw: [Any]
        if let one = value as? String { raw = [one] } else if let many = value as? [Any] { raw = many } else {
            throw ChiefControlParamError.invalid("choices")
        }
        guard raw.count <= maxChoices else { throw ChiefControlParamError.tooLong("choices") }
        return try raw.map { item in
            guard let string = item as? String else { throw ChiefControlParamError.invalid("choices") }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ChiefControlParamError.invalid("choices") }
            guard trimmed.count <= maxChoiceLength else { throw ChiefControlParamError.tooLong("choices") }
            return trimmed
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
    /// Slides the Chief Settings panel in, as the header's name pill does.
    case openSettings
    /// Slides the Chief Settings panel out.
    case closeSettings
    /// Opens the memory sheet on the transcript's window (Settings' Show All).
    case openMemory
    /// Closes the memory sheet, saving an edit as Done does.
    case closeMemory
    /// Expands the newest collapsed "Ran N commands" run on screen.
    case expandTools
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
