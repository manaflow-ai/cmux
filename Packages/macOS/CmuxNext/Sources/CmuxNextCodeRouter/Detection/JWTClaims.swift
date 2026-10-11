import Foundation

/// The payload claims of a JWT, decoded without verifying the signature.
/// Used only for non-secret identity fields (email, plan, expiry) of a
/// token the user's own CLI stored; the token itself is never kept.
struct JWTClaims {
    let values: [String: Any]

    init?(token: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        values = object
    }

    var email: String? { (values["email"] as? String).flatMap { $0.isEmpty ? nil : $0 } }

    /// `exp` as a date.
    var expiry: Date? {
        if let seconds = values["exp"] as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = values["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        return nil
    }

    /// The ChatGPT plan OpenAI puts in Codex tokens (`plus`, `pro`, `team`).
    var chatGPTPlan: String? {
        let auth = values["https://api.openai.com/auth"] as? [String: Any]
        return (auth?["chatgpt_plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
