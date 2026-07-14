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
            let sanitizedItems = redactingSensitiveValues(in: queryItems)
            if sanitizedItems != queryItems { components.queryItems = sanitizedItems }
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
            return containsSensitiveFieldName(fragment) ? nil : fragment
        }
        let sanitizedItems = redactingSensitiveValues(in: queryItems)
        guard sanitizedItems != queryItems else { return fragment }
        query.queryItems = sanitizedItems
        let separator = includesQuestionMark ? "?" : ""
        return "\(prefix)\(separator)\(query.percentEncodedQuery ?? "")"
    }

    private func redactingSensitiveValues(in items: [URLQueryItem]) -> [URLQueryItem] {
        items.map { item in
            guard containsSensitiveFieldName(item.name) else { return item }
            return URLQueryItem(name: item.name, value: "<redacted>")
        }
    }

    private func containsSensitiveFieldName(_ value: String) -> Bool {
        let boundaryNormalized = value.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1-$2",
            options: .regularExpression
        )
        return boundaryNormalized.range(
            of: #"(?:^|[-_.:])(api[-_]?key|auth|authorization|code|credential|csrf|password|passwd|secret|session|token)(?:$|[-_.:])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
