import Foundation

/// Recognizes the server responses that authorize a deferred credential lookup.
enum SocketAuthenticationChallenge {
    private static let challengeMarker = "send auth <password> first"

    /// Returns `true` only for the control-socket authentication challenge.
    static func isRequired(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return trimmed.lowercased().contains(challengeMarker)
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              (error["code"] as? String)?.lowercased() == "auth_required",
              let message = error["message"] as? String else {
            return false
        }
        return message.lowercased().contains(challengeMarker)
    }
}
