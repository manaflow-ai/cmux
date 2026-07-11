import Foundation

struct TranscriptPrivacySanitizer {
    static func identifier(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 120 else {
            return "non_identifier"
        }
        for scalar in value.unicodeScalars {
            guard allowedScalars.contains(scalar) else {
                return "non_identifier"
            }
        }
        return value
    }

    private static let allowedScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-")
}
