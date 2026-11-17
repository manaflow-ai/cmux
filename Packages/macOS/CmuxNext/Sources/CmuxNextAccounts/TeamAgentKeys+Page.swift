public import CmuxNextSettings
import CmuxNextDesign
import Foundation

/// The "Team agent keys" card of Settings > Accounts (webviews TeamAgentKeysCard.tsx). Every text is
/// localized here; the page only draws it and sends `agentKeySave`, `agentKeyRemove`, `agentKeyRefresh`.
/// It never carries a key: only whether one is set, its kind, its last four characters (admins) and when.
extension TeamAgentKeys {
    public var pageState: JSONValue {
        let note: String?
        if scopeIsSignedOut { note = Self.signInText }
        else if isPersonal { note = Self.personal }
        else if loaded, !canManage { note = Self.memberNote }
        else { note = nil }
        let problem = currentProblem
        let finished = currentDone
        let agents: [JSONValue] = currentAgents.map { row in
            let agent = row["agent"]?.stringValue ?? ""
            let set = row["set"]?.boolValue == true
            let error = problem?.agent == agent ? problem.map { Self.copy($0.code) } : nil
            let notice = finished?.agent == agent && error == nil ? (finished?.removed == true ? Self.removed : Self.saved) : nil
            return [
                "agent": .string(agent),
                "name": .string(Self.name(agent)),
                "set": .bool(set),
                "status": .string(set ? Self.setStatus : Self.notSet),
                "detail": detail(row).map(JSONValue.string) ?? .null,
                "error": error.map(JSONValue.string) ?? .null,
                "notice": notice.map(JSONValue.string) ?? .null,
            ]
        }
        let cardError = problem.flatMap { $0.agent == nil ? Self.loadFailed($0.code) : nil }
        return [
            "title": .string(Self.title),
            "detail": .string(Self.detailText),
            "note": note.map(JSONValue.string) ?? .null,
            "signIn": scopeIsSignedOut ? .string(SignInButton.defaultTitle) : .null,
            "busy": .bool(busy),
            "canManage": .bool(canManage),
            "error": cardError.map(JSONValue.string) ?? .null,
            "refresh": .string(Self.refreshTitle),
            "labels": [
                "add": .string(Self.add), "replace": .string(Self.replace), "remove": .string(Self.removeTitle),
                "confirmRemove": .string(Self.confirmRemove), "cancel": .string(Self.cancel), "save": .string(Self.save),
                "kind": .string(Self.kindLabel), "secret": .string(Self.secretLabel), "placeholder": .string(Self.placeholder),
            ],
            "kinds": .array(Self.kinds.map { ["id": .string($0), "title": .string(Self.kindTitle($0))] }),
            "agents": .array(agents),
        ]
    }

    /// "API key · Ending in …abcd · Updated Nov 7, 2026", or nil for an unset key.
    private func detail(_ row: JSONValue) -> String? {
        guard row["set"]?.boolValue == true else { return nil }
        var parts: [String] = []
        if let kind = row["kind"]?.stringValue, Self.kinds.contains(kind) { parts.append(Self.kindTitle(kind)) }
        if let hint = row["hint"]?.stringValue, !hint.isEmpty { parts.append(String(format: Self.endingIn, hint)) }
        if let ms = row["updated_at"]?.doubleValue {
            parts.append(String(format: Self.updated, Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension TeamAgentKeys {
    static var title: String { String(localized: "teamAgentKeys.title", defaultValue: "Team agent keys", table: "TeamAgentKeys", bundle: .module) }
    static var detailText: String { String(localized: "teamAgentKeys.detail", defaultValue: "A team key is used for every member's Claude or Codex runs on this team's Cloud machines, in place of their own keys.", table: "TeamAgentKeys", bundle: .module) }
    static var signInText: String { String(localized: "teamAgentKeys.signIn", defaultValue: "Sign in to cmux to see your team's agent keys.", table: "TeamAgentKeys", bundle: .module) }
    static var personal: String { String(localized: "teamAgentKeys.personal", defaultValue: "Your personal team has no one to share keys with. Switch to a team to manage its keys.", table: "TeamAgentKeys", bundle: .module) }
    static var memberNote: String { String(localized: "teamAgentKeys.member", defaultValue: "Your team's owners and admins manage these keys.", table: "TeamAgentKeys", bundle: .module) }
    static var setStatus: String { String(localized: "teamAgentKeys.status.set", defaultValue: "Team key set", table: "TeamAgentKeys", bundle: .module) }
    static var notSet: String { String(localized: "teamAgentKeys.status.notSet", defaultValue: "Not set", table: "TeamAgentKeys", bundle: .module) }
    static var endingIn: String { String(localized: "teamAgentKeys.endingIn", defaultValue: "Ending in …%@", table: "TeamAgentKeys", bundle: .module) }
    static var updated: String { String(localized: "teamAgentKeys.updated", defaultValue: "Updated %@", table: "TeamAgentKeys", bundle: .module) }
    static var saved: String { String(localized: "teamAgentKeys.saved", defaultValue: "Team key saved.", table: "TeamAgentKeys", bundle: .module) }
    static var removed: String { String(localized: "teamAgentKeys.removed", defaultValue: "Team key removed. Members' own keys apply again.", table: "TeamAgentKeys", bundle: .module) }
    static var add: String { String(localized: "teamAgentKeys.add", defaultValue: "Add Key", table: "TeamAgentKeys", bundle: .module) }
    static var replace: String { String(localized: "teamAgentKeys.replace", defaultValue: "Replace", table: "TeamAgentKeys", bundle: .module) }
    static var removeTitle: String { String(localized: "teamAgentKeys.remove", defaultValue: "Remove", table: "TeamAgentKeys", bundle: .module) }
    static var confirmRemove: String { String(localized: "teamAgentKeys.confirmRemove", defaultValue: "Remove this team key? Members' runs on the team's Cloud machines go back to their own keys.", table: "TeamAgentKeys", bundle: .module) }
    static var cancel: String { String(localized: "teamAgentKeys.cancel", defaultValue: "Cancel", table: "TeamAgentKeys", bundle: .module) }
    static var save: String { String(localized: "teamAgentKeys.save", defaultValue: "Save", table: "TeamAgentKeys", bundle: .module) }
    static var kindLabel: String { String(localized: "teamAgentKeys.kind", defaultValue: "Key type", table: "TeamAgentKeys", bundle: .module) }
    static var secretLabel: String { String(localized: "teamAgentKeys.secret", defaultValue: "Key", table: "TeamAgentKeys", bundle: .module) }
    static var placeholder: String { String(localized: "teamAgentKeys.placeholder", defaultValue: "Paste the key", table: "TeamAgentKeys", bundle: .module) }
    static var refreshTitle: String { String(localized: "teamAgentKeys.refresh", defaultValue: "Refresh", table: "TeamAgentKeys", bundle: .module) }

    /// The agent names Settings uses everywhere (product names, the same in every language).
    static func name(_ agent: String) -> String { agent == "codex" ? "Codex" : "Claude" }

    static func kindTitle(_ kind: String) -> String {
        kind == "oauth"
            ? String(localized: "teamAgentKeys.kind.oauth", defaultValue: "Subscription token", table: "TeamAgentKeys", bundle: .module)
            : String(localized: "teamAgentKeys.kind.apiKey", defaultValue: "API key", table: "TeamAgentKeys", bundle: .module)
    }

    /// The copy for an API error code of a save or removal.
    static func copy(_ code: String) -> String {
        switch code {
        case "auth.forbidden": String(localized: "teamAgentKeys.error.forbidden", defaultValue: "Only team owners and admins can change team keys.", table: "TeamAgentKeys", bundle: .module)
        case "validation.invalid": String(localized: "teamAgentKeys.error.invalid", defaultValue: "This key is not valid. Paste the whole key or sign-in file again.", table: "TeamAgentKeys", bundle: .module)
        case "revision.conflict": String(localized: "teamAgentKeys.error.conflict", defaultValue: "Another admin changed this key; try again.", table: "TeamAgentKeys", bundle: .module)
        case "team_agent_key.not_configured": notConfigured
        case "owner.unreachable": String(localized: "teamAgentKeys.error.unreachable", defaultValue: "The Cloud service could not be reached. Try again.", table: "TeamAgentKeys", bundle: .module)
        default: String(localized: "teamAgentKeys.error.failed", defaultValue: "The team key could not be changed. Refresh to try again.", table: "TeamAgentKeys", bundle: .module)
        }
    }

    /// The copy for a failed status read.
    static func loadFailed(_ code: String) -> String {
        switch code {
        case "auth.forbidden": String(localized: "teamAgentKeys.error.notMember", defaultValue: "You are no longer a member of this team.", table: "TeamAgentKeys", bundle: .module)
        case "team_agent_key.not_configured": notConfigured
        default: String(localized: "teamAgentKeys.error.load", defaultValue: "Team keys could not be loaded. Refresh to try again.", table: "TeamAgentKeys", bundle: .module)
        }
    }

    static var notConfigured: String { String(localized: "teamAgentKeys.error.notConfigured", defaultValue: "Team keys are not available on this Cloud service yet.", table: "TeamAgentKeys", bundle: .module) }
}
