import Foundation

/// Recognizes the server responses that authorize a deferred credential lookup.
public nonisolated enum SocketAuthenticationChallenge {
    private static let challengeMarker = "send auth <password> first"
    private static let nonSocketAuthMarkers = ["cloud vm", "sign-in", "cmux auth login"]

    /// Returns `true` only for the control-socket authentication challenge.
    public static func isRequired(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedResponse = trimmed.lowercased()
        if normalizedResponse.hasPrefix("error:") {
            return !nonSocketAuthMarkers.contains(where: normalizedResponse.contains)
                && normalizedResponse.contains(challengeMarker)
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

    /// Returns whether a response positively proves credential-free access.
    ///
    /// A non-challenge error is not proof of allow-all mode. Restricting this
    /// transition to explicit success responses keeps a failed or unrelated
    /// request from suppressing a later authentication probe.
    public static func isCredentialFreeSuccess(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("error:") {
            return false
        }
        if normalized == "ok" || normalized == "pong" ||
            normalized.hasPrefix("ok ") || normalized.hasPrefix("ok:") {
            return true
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return (object["ok"] as? Bool) == true
    }
}
