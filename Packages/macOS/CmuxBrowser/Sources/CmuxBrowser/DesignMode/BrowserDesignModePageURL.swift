import Foundation

/// Sanitizes one page URL before it enters a design-mode agent handoff.
nonisolated struct BrowserDesignModePageURL {
    private let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var sanitizedValue: String {
        guard var components = URLComponents(string: rawValue) else { return "" }
        components.user = nil
        components.password = nil
        if let queryItems = components.queryItems {
            components.queryItems = redactingValues(in: queryItems)
        }
        if let fragment = components.fragment {
            components.fragment = sanitizedFragment(fragment)
        }
        return components.string ?? ""
    }

    private func sanitizedFragment(_ fragment: String) -> String? {
        let prefix: Substring
        let encodedQuery: Substring
        let includesQuestionMark: Bool
        if let questionMark = fragment.firstIndex(of: "?") {
            prefix = fragment[..<questionMark]
            encodedQuery = fragment[fragment.index(after: questionMark)...]
            includesQuestionMark = true
        } else if fragment.contains("=") {
            prefix = ""
            encodedQuery = Substring(fragment)
            includesQuestionMark = false
        } else {
            return fragment
        }

        var query = URLComponents()
        query.percentEncodedQuery = String(encodedQuery)
        guard let queryItems = query.queryItems, !queryItems.isEmpty else {
            return nil
        }
        query.queryItems = redactingValues(in: queryItems)
        let separator = includesQuestionMark ? "?" : ""
        return "\(prefix)\(separator)\(query.percentEncodedQuery ?? "")"
    }

    private func redactingValues(in items: [URLQueryItem]) -> [URLQueryItem] {
        items.map { item in
            URLQueryItem(
                name: item.name,
                value: item.value == nil ? nil : "<redacted>"
            )
        }
    }
}
