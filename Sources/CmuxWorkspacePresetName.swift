import Foundation

enum CmuxWorkspacePresetName {
    static let fallbackName = "workspace"

    static func normalized(_ raw: String?, fallbackName: String = Self.fallbackName) -> String {
        let trimmedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulRaw = trimmedRaw?.isEmpty == false ? trimmedRaw : nil
        let candidates: [String?] = [
            meaningfulRaw,
            meaningfulRaw.flatMap(Self.sanitizedCandidate),
            fallbackName,
            Self.sanitizedCandidate(fallbackName),
            Self.fallbackName
        ]

        for candidate in candidates {
            if let valid = valid(candidate) {
                return valid
            }
        }
        return Self.fallbackName
    }

    static func sanitizedComponent(_ raw: String) -> String {
        sanitizedCandidate(raw) ?? Self.fallbackName
    }

    private static func sanitizedCandidate(_ raw: String) -> String? {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func valid(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard !trimmed.hasPrefix(".") else { return nil }
        guard !trimmed.contains("..") else { return nil }
        return trimmed
    }
}
