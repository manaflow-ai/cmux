import Foundation

enum CmuxWorkspacePresetName {
    static let fallbackName = "workspace"

    static func normalized(_ raw: String?, fallbackName: String = Self.fallbackName) -> String {
        let candidates: [String?] = [
            raw,
            raw.map(Self.sanitizedComponent),
            fallbackName,
            Self.sanitizedComponent(fallbackName),
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
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? Self.fallbackName : trimmed
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
