import CmuxSettings

/// Editable override fields reconciled against authoritative JSON snapshots.
struct ChromeTokenOverrideDrafts: Equatable {
    private(set) var values: [ChromeToken: String]
    private(set) var dirtyTokens: Set<ChromeToken> = []
    private(set) var invalidTokens: Set<ChromeToken> = []

    init(overrides: ChromeTokenOverrides) {
        values = overrides.hexValues.reduce(into: [:]) { result, entry in
            guard let token = ChromeToken(rawValue: entry.key) else { return }
            result[token] = entry.value
        }
    }

    subscript(token: ChromeToken) -> String {
        values[token] ?? ""
    }

    func isInvalid(_ token: ChromeToken) -> Bool {
        invalidTokens.contains(token)
    }

    func trimmedValue(for token: ChromeToken) -> String {
        self[token].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func edit(_ value: String, for token: ChromeToken) {
        values[token] = value
        dirtyTokens.insert(token)
        invalidTokens.remove(token)
    }

    mutating func markInvalid(_ token: ChromeToken) {
        dirtyTokens.insert(token)
        invalidTokens.insert(token)
    }

    mutating func stageCanonicalValue(_ value: String, for token: ChromeToken) {
        values[token] = value
        dirtyTokens.insert(token)
        invalidTokens.remove(token)
    }

    mutating func synchronize(with overrides: ChromeTokenOverrides) {
        for token in ChromeToken.allCases {
            let authoritative = overrides[token]?.hex ?? ""
            guard dirtyTokens.contains(token) else {
                values[token] = authoritative
                invalidTokens.remove(token)
                continue
            }

            let raw = trimmedValue(for: token)
            let normalized: String?
            if raw.isEmpty {
                normalized = ""
            } else {
                normalized = ChromeColor(hex: raw)?.hex
            }
            guard normalized == authoritative else { continue }
            values[token] = authoritative
            dirtyTokens.remove(token)
            invalidTokens.remove(token)
        }
    }
}
