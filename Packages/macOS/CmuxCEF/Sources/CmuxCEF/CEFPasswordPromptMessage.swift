public import Foundation

/// The fork's password prompt (`CMUX_SHIM_PASSWORD_PROMPT`, fork API 20):
/// Chromium's offer to save or update a submitted sign-in, asked by cmux
/// instead of Chromium's bubble (which anchors to a toolbar cmux hides), or
/// the end of one. Only the origin and user name come here; never the
/// password. Same contract as cmux Next `CEFPasswordPrompts`.
public enum CEFPasswordPromptMessage: Equatable, Sendable {
    /// Chromium asks whether to save (or, for a saved sign-in, update) the password.
    case offer(origin: String, username: String, isUpdate: Bool)
    /// The tab navigated or closed: Chromium dropped the prompt.
    case gone

    /// Parses the event's JSON (`{"kind": "save" | "update" | "gone",
    /// "origin", "username", …}`); `nil` for anything else.
    public init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "save", "update":
            self = .offer(
                origin: object["origin"] as? String ?? "",
                username: object["username"] as? String ?? "",
                isUpdate: kind == "update"
            )
        case "gone":
            self = .gone
        default:
            return nil
        }
    }
}

/// `cmux_password_prompt_action_t`: the answer `cmux_shim_password_prompt_answer` takes.
public enum CEFPasswordPromptAction: Int32, Sendable {
    case save = 0
    case update = 1
    /// Never offer for this site again.
    case never = 2
    case dismiss = 3
}
