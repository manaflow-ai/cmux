import Foundation

/// Recognizes the server responses that authorize a deferred credential lookup.
enum SocketAuthenticationChallenge {
    /// Returns `true` only for the control-socket authentication challenge.
    static func isRequired(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return trimmed.range(of: "authentication required", options: .caseInsensitive) != nil
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return false
        }
        return (error["code"] as? String)?.lowercased() == "auth_required"
    }
}
