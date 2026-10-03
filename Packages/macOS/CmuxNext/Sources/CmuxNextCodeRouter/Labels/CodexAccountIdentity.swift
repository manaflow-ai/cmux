import Foundation
import os

/// The identity behind a Codex (ChatGPT) account handle: the ChatGPT
/// workspace id and the user id. Local detection reads them from the
/// `~/.codex/auth.json` tokens; the CodeRouter row carries the same values
/// as `providerAccountId` (workspace) and `providerUserId` (user). Both
/// sides build the same identity string, so one sign-in has one handle
/// everywhere, and no label (email-shaped or not) ever changes it.
///
/// Order, when an id is missing (each step but the first logs, without
/// values, that the handle is unstable):
/// 1. workspace + user: `codex:workspace:<ws>:user:<user>` (stable).
/// 2. workspace only: `codex:workspace:<ws>` (a legacy server row; two
///    users in one workspace share it).
/// 3. user only: `codex:user:<user>`.
/// 4. neither: the caller's fallback (the server row id, or the token's own
///    email claim locally). Never a label.
struct CodexAccountIdentity: Equatable {
    let workspaceID: String?
    let userID: String?

    init(workspaceID: String?, userID: String?) {
        self.workspaceID = Self.clean(workspaceID)
        self.userID = Self.clean(userID)
    }

    /// The claims the server's owner check reads (web/services/coderouter/codexIdentity.ts):
    /// `chatgpt_account_id` and `chatgpt_user_id`, top level or under
    /// `https://api.openai.com/auth`, in the id and access tokens; the
    /// legacy `user_id` under the auth claim of the id token; and
    /// `tokens.account_id` for the workspace. Two different values for one
    /// id count as missing (the server refuses such a credential).
    init(idToken: JWTClaims?, accessToken: JWTClaims?, accountIDField: String?) {
        let claims = [idToken, accessToken].compactMap { $0 }
        let workspaces = Set(claims.flatMap { $0.strings(named: "chatgpt_account_id") })
        var users = Set(claims.flatMap { $0.strings(named: "chatgpt_user_id") })
        if users.isEmpty, let legacy = idToken?.openAIAuthString("user_id") { users.insert(legacy) }
        let workspace = workspaces.count == 1 ? workspaces.first : (workspaces.isEmpty ? accountIDField : nil)
        self.init(workspaceID: workspace, userID: users.count == 1 ? users.first : nil)
    }

    /// Why a handle is not the stable workspace + user form. Never a value.
    enum Instability: String {
        case missingUser = "no user id"
        case missingWorkspace = "no workspace id"
        case missingBoth = "no workspace or user id"
    }

    var instability: Instability? {
        switch (workspaceID, userID) {
        case (.some, .some): nil
        case (.some, nil): .missingUser
        case (nil, .some): .missingWorkspace
        case (nil, nil): .missingBoth
        }
    }

    /// The identity string, or nil when both ids are missing.
    var identity: String? {
        switch (workspaceID.map(Self.escape), userID.map(Self.escape)) {
        case let (workspace?, user?): "codex:workspace:\(workspace):user:\(user)"
        case let (workspace?, nil): "codex:workspace:\(workspace)"
        case let (nil, user?): "codex:user:\(user)"
        case (nil, nil): nil
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "coderouter.labels")

    /// Logs (no values) that a Codex handle is not stable.
    static func logUnstable(_ reason: Instability, source: String) {
        logger.notice("codex account handle is unstable (\(reason.rawValue, privacy: .public), \(source, privacy: .public))")
    }

    private static func clean(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// `%` and `:` are escaped, so an id can never shift the string's fields.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ":", with: "%3A")
    }
}

extension JWTClaims {
    /// `name` at the top level and under `https://api.openai.com/auth`.
    func strings(named name: String) -> [String] {
        [values[name] as? String, openAIAuthString(name)].compactMap { $0?.nilIfEmpty }
    }

    /// One string under `https://api.openai.com/auth`.
    func openAIAuthString(_ name: String) -> String? {
        ((values["https://api.openai.com/auth"] as? [String: Any])?[name] as? String)?.nilIfEmpty
    }
}
