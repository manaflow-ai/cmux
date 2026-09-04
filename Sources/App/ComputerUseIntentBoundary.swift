import CMUXAgentLaunch
import Foundation

/// Defines the host-side boundary between passive Computer Use plumbing and an
/// explicit request that may require the permission onboarding flow.
///
/// The boundary consumes accepted workstream hook events only. Helper startup,
/// MCP handshake/discovery, permission-status probes, and arbitrary
/// presentation text do not constitute intent. A protected namespaced tool
/// call, a canonical `$cmux-cua` prompt, or an explicitly executed skill call
/// does.
struct ComputerUseIntentBoundary {
    /// The reason a workstream event is allowed to request onboarding.
    enum Kind: Equatable, Hashable, Sendable {
        case explicitPrompt
        case explicitSkill
        case protectedAction(toolName: String)

        var isProtectedAction: Bool {
            if case .protectedAction = self { return true }
            return false
        }
    }

    /// Stable identity used to keep intent scoped to one agent surface.
    struct Session: Equatable, Hashable, Sendable {
        let source: String
        let sessionID: String
        let surfaceID: String?

        init(
            source: String,
            sessionID: String,
            surfaceID: String?
        ) {
            self.source = source
            self.sessionID = sessionID
            self.surfaceID = surfaceID
        }

        init?(event: WorkstreamEvent) {
            guard
                let source = Self.normalized(event.source),
                let sessionID = Self.normalized(event.sessionId)
            else {
                return nil
            }
            self.source = source.lowercased()
            self.sessionID = sessionID
            self.surfaceID = Self.normalizedSurface(event.surfaceId)
        }

        private static func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func normalizedSurface(_ value: String?) -> String? {
            guard let value = normalized(value) else { return nil }
            if let uuid = UUID(uuidString: value) {
                return uuid.uuidString.lowercased()
            }
            return value
        }
    }

    /// One explicit request, retained so retries and concurrent hook events
    /// share a single onboarding claim.
    struct Signal: Equatable, Sendable {
        let kind: Kind
        let session: Session
        let requestToken: String
    }

    /// A prompt boundary optionally carrying an explicit Computer Use signal.
    struct TurnStart: Equatable, Sendable {
        let session: Session
        let token: String?
        let signal: Signal?
    }

    /// Lifecycle observation consumed by ``ComputerUseIntentBoundary.Ledger``.
    enum Observation: Equatable, Sendable {
        case ignored
        case turnStarted(TurnStart)
        case request(Signal)
        case completed(Session)
    }

    /// Classifies one accepted workstream event without consulting UI state.
    ///
    /// ``WorkstreamEvent`` is the authoritative intent ingress: the event has
    /// already crossed Feed's ownership/target validation before the app posts
    /// it to the coordinator. Only structured hook fields are inspected; no
    /// assistant transcript, window title, or rendered UI string can arm the
    /// gate.
    static func observation(for event: WorkstreamEvent) -> Observation {
        guard let session = Session(event: event) else { return .ignored }

        switch event.hookEventName {
        case .userPromptSubmit:
            let prompt = promptText(from: event)
            let token = requestToken(
                for: event,
                label: "turn",
                semanticText: prompt
            )
            let signal: Signal?
            if isExplicitPrompt(prompt) || hasExplicitIntentMarker(in: event) {
                signal = Signal(
                    kind: .explicitPrompt,
                    session: session,
                    requestToken: token
                )
            } else {
                signal = nil
            }
            return .turnStarted(
                TurnStart(
                    session: session,
                    token: token,
                    signal: signal
                )
            )

        case .preToolUse:
            if let toolName = protectedToolName(from: event) {
                return .request(
                    Signal(
                        kind: .protectedAction(toolName: toolName),
                        session: session,
                        requestToken: requestToken(
                            for: event,
                            label: toolName,
                            semanticText: nil
                        )
                    )
                )
            }
            if hasExplicitIntentMarker(in: event) || isExplicitSkillInvocation(event) {
                return .request(
                    Signal(
                        kind: .explicitSkill,
                        session: session,
                        requestToken: requestToken(
                            for: event,
                            label: "skill",
                            semanticText: nil
                        )
                    )
                )
            }
            if event.toolName != nil {
                // This includes check_permissions, health/config probes,
                // cursor bookkeeping, and session/recording lifecycle calls.
                return .ignored
            }
            return .ignored

        case .stop, .sessionEnd:
            return .completed(session)

        default:
            return .ignored
        }
    }

    /// Compatibility predicate used by the cursor/session projection. It is
    /// deliberately narrower than ``observation(for:)``: a user prompt or
    /// skill load can arm onboarding, but cannot start a live driver session.
    static func isProtectedToolInvocation(_ event: WorkstreamEvent) -> Bool {
        guard case .request(let signal) = observation(for: event) else {
            return false
        }
        return signal.kind.isProtectedAction
    }

    /// Extracts a canonical CUA tool name from a namespaced MCP hook field.
    ///
    /// The namespace is the authority. Bare `click`/`type_text` names are not
    /// accepted unless the producer supplied an explicit `cmux-cua` server
    /// marker in the preserved extra fields, preventing another agent's tool
    /// with the same name from opening onboarding.
    static func protectedToolName(from event: WorkstreamEvent) -> String? {
        guard let rawToolName = normalized(event.toolName) else { return nil }
        let lower = rawToolName.lowercased()
        let prefixes = [
            "mcp__cmux-cua__",
            "mcp__cmux_cua__",
            "cmux-cua.",
            "cmux_cua.",
        ]
        let namespacedName = prefixes.lazy
            .compactMap { prefix -> String? in
                guard lower.hasPrefix(prefix) else { return nil }
                let suffix = String(lower.dropFirst(prefix.count))
                return suffix.isEmpty ? nil : suffix
            }
            .first

        let candidate: String?
        if let namespacedName {
            candidate = namespacedName
        } else if extraServerName(from: event) == "cmux-cua",
                  !rawToolName.contains(where: { $0.isWhitespace }) {
            candidate = lower
        } else {
            candidate = nil
        }
        guard let candidate, !passiveToolNames.contains(candidate) else {
            return nil
        }
        return candidate
    }

    /// The passive names are intentionally explicit. Unknown names in the
    /// authenticated `cmux-cua` namespace remain eligible so adding a new
    /// protected tool does not silently disable its first-use gate.
    private static let passiveToolNames: Set<String> = [
        "check_permissions",
        "health_report",
        "get_config",
        "set_config",
        "get_screen_size",
        "get_cursor_position",
        "get_agent_cursor_state",
        "set_agent_cursor_enabled",
        "set_agent_cursor_motion",
        "set_agent_cursor_style",
        "get_recording_state",
        "recording_status",
        "recording_start",
        "recording_stop",
        "start_recording",
        "stop_recording",
        "session_status",
        "session_begin",
        "session_end",
        "end_session",
    ]

    private static let skillToolNames: Set<String> = [
        "skill",
        "load_skill",
        "use_skill",
        "invoke_skill",
        "skill_use",
    ]

    private static let intentVerbs: Set<String> = [
        "use", "using", "open", "click", "drive", "operate", "control",
        "invoke", "run", "start", "enable",
    ]

    private static let reportingWords: Set<String> = [
        "says", "said", "shows", "showing", "text", "label", "title",
        "mentions", "mention", "describes", "description", "contains",
        "reads", "read",
    ]

    private static let explanatoryWords: Set<String> = [
        "about", "define", "definition", "docs", "document", "documentation",
        "explain", "explaining", "how", "meaning", "tell", "what",
    ]

    private static let negationWords: Set<String> = [
        "don't", "dont", "do", "not", "without", "never", "avoid",
        "can't", "cant", "isn't", "isnt",
    ]

    private static func isExplicitPrompt(_ prompt: String?) -> Bool {
        guard let prompt else { return false }
        let words = lexicalWords(in: prompt)
        guard !words.isEmpty else { return false }
        if words.contains("$cmux-cua") { return true }

        guard words.count >= 3 else { return false }
        for index in 0 ... (words.count - 3) {
            guard words[index] == "cmux",
                  words[index + 1] == "computer",
                  words[index + 2] == "use"
            else { continue }

            let beforeStart = max(0, index - 4)
            let before = Array(words[beforeStart ..< index])
            let afterEnd = min(words.count, index + 7)
            let after = Array(words[(index + 3) ..< afterEnd])
            guard !before.contains(where: reportingWords.contains) else {
                continue
            }
            let context = before.suffix(4)
            guard !context.contains(where: explanatoryWords.contains) else {
                continue
            }
            let negated = context.contains(where: negationWords.contains)
            guard !negated else { continue }

            let directBefore = before.last.map(intentVerbs.contains) == true
                || (before.count >= 2
                    && before.suffix(2).first.map(intentVerbs.contains) == true
                    && before.last == "the")
            let directAfter = after.first.map(intentVerbs.contains) == true
                || (after.first == "to"
                    && after.dropFirst().first.map(intentVerbs.contains) == true)
            if directBefore || directAfter {
                return true
            }
        }
        return false
    }

    private static func isExplicitSkillInvocation(_ event: WorkstreamEvent) -> Bool {
        guard let rawToolName = normalized(event.toolName) else { return false }
        let toolName = rawToolName.lowercased()
        guard skillToolNames.contains(toolName) else { return false }
        guard let input = toolInputDictionary(from: event.toolInputJSON) else {
            return false
        }
        let name = ["skill", "skill_name", "name", "slug", "command"]
            .compactMap { input[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { $0 == "cmux-cua" || $0 == "$cmux-cua" }
        guard name != nil else { return false }

        // A picker/catalog scan is not an invocation. Newer wrappers mark the
        // executable skill call explicitly; the canonical `$cmux-cua` command
        // is itself an explicit marker for older clients.
        let explicitlyInvoked = ["explicit", "user_invoked", "invoked"]
            .compactMap { input[$0] as? Bool }
            .contains(true)
        let commandContainsToken = (input["command"] as? String)?
            .contains("$cmux-cua") == true
        return explicitlyInvoked || commandContainsToken || name == "$cmux-cua"
    }

    private static func hasExplicitIntentMarker(in event: WorkstreamEvent) -> Bool {
        guard let fields = extraFields(from: event) else { return false }
        for key in ["computer_use_intent", "cmux_computer_use_intent"] {
            guard let raw = fields[key] else { continue }
            if let flag = raw as? Bool, flag { return true }
            if let value = raw as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "explicit", "requested", "user", "skill", "protected":
                    return true
                default:
                    break
                }
            }
        }
        return false
    }

    private static func promptText(from event: WorkstreamEvent) -> String? {
        if let prompt = normalized(event.context?.lastUserMessage) {
            return prompt
        }
        guard let input = toolInputDictionary(from: event.toolInputJSON) else {
            return nil
        }
        return ["prompt", "text", "message"]
            .compactMap { input[$0] as? String }
            .compactMap(normalized)
            .first
    }

    private static func requestToken(
        for event: WorkstreamEvent,
        label: String,
        semanticText: String?
    ) -> String {
        // Prompt text is the stable identity for duplicate UserPromptSubmit
        // callbacks in one turn; generated hook request ids often include a
        // fresh timestamp. The ledger's completed-turn bit still separates
        // two later turns that happen to repeat the same prompt.
        if label == "turn", let semanticText = normalized(semanticText) {
            return "\(label):\(digest(semanticText))"
        }
        if let requestID = normalized(event.requestId) {
            return "request:\(digest(requestID))"
        }
        if let semanticText = normalized(semanticText) {
            return "\(label):\(digest(semanticText))"
        }
        let seed = label == "turn"
            ? "\(event.sessionId)|\(event.receivedAt.timeIntervalSince1970.bitPattern)"
            : event.sessionId
        return "\(label):\(digest(seed))"
    }

    private static func digest(_ value: String) -> String {
        // FNV-1a is used only as an in-process deduplication key; no user text
        // is persisted or exposed in diagnostics.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func lexicalWords(in value: String) -> [String] {
        value.lowercased()
            .split { character in
                !(character.isLetter
                    || character.isNumber
                    || character == "$"
                    || character == "-"
                    || character == "_")
            }
            .map(String.init)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func toolInputDictionary(from raw: String?) -> [String: Any]? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              )
        else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func extraServerName(from event: WorkstreamEvent) -> String? {
        guard let fields = extraFields(from: event) else { return nil }
        return ["mcp_server", "server", "namespace"]
            .compactMap { fields[$0] as? String }
            .compactMap(normalized)
            .map { $0.lowercased() }
            .first
    }

    private static func extraFields(from event: WorkstreamEvent) -> [String: Any]? {
        guard let raw = event.extraFieldsJSON,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else {
            return nil
        }
        return fields
    }

}
