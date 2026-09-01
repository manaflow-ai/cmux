import Foundation

/// Recognizes the server responses that authorize a deferred credential lookup.
public nonisolated enum SocketAuthenticationChallenge {
    private static let challengeMarker = "send auth <password> first"
    private static let nonSocketAuthMarkers = ["cloud vm", "sign-in", "cmux auth login"]

    /// Returns `true` only for the control-socket authentication challenge.
    public static func isRequired(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return trimmed.lowercased().contains(challengeMarker)
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let code = (error["code"] as? String)?.lowercased(),
              code == "auth_required" else {
            return false
        }
        guard let message = error["message"] as? String else { return false }
        let normalizedMessage = message.lowercased()
        guard !nonSocketAuthMarkers.contains(where: normalizedMessage.contains) else {
            return false
        }
        return normalizedMessage.contains(challengeMarker)
    }
}
