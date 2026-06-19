import CmuxAuthRuntime
import CmuxControlSocket

extension AuthSocketStatusPayload {
    var controlSocketPayload: JSONValue {
        var object: [String: JSONValue] = [
            "signed_in": .bool(signedIn),
            "is_restoring_session": .bool(isRestoringSession),
            "is_loading": .bool(isLoading),
            "timed_out": .bool(timedOut),
        ]
        if let user {
            object["user"] = user.controlSocketPayload
        }
        if let selectedTeamID {
            object["selected_team_id"] = .string(selectedTeamID)
        }
        if !teams.isEmpty {
            object["teams"] = .array(teams.map(\.controlSocketPayload))
        }
        return .object(object)
    }
}

extension AuthSocketSignInURLPayload {
    var controlSocketPayload: JSONValue {
        guard let url else { return .object([:]) }
        return .object(["url": .string(url)])
    }
}

private extension AuthSocketUserPayload {
    var controlSocketPayload: JSONValue {
        var object: [String: JSONValue] = ["id": .string(id)]
        if let email {
            object["email"] = .string(email)
        }
        if let displayName {
            object["display_name"] = .string(displayName)
        }
        return .object(object)
    }
}

private extension AuthSocketTeamPayload {
    var controlSocketPayload: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "display_name": .string(displayName),
        ]
        if let slug {
            object["slug"] = .string(slug)
        }
        return .object(object)
    }
}
