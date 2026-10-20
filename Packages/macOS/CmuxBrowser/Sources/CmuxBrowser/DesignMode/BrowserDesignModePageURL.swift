import Foundation

/// Keeps URL structure while redacting route and value content before agent handoff.
struct BrowserDesignModePageURL {
    private static let maxInputUTF8Bytes = 8_192
    private static let maxOutputUTF8Bytes = 4_096
    private let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var sanitizedValue: String {
        guard isWithinUTF8Limit(rawValue, limit: Self.maxInputUTF8Bytes) else { return "" }
        guard var components = URLComponents(string: rawValue) else { return "" }
        components.user = nil
        components.password = nil
        components.percentEncodedPath = redactedRoute(components.percentEncodedPath)
        if let queryItems = components.queryItems {
            components.queryItems = redactingValues(in: queryItems)
        }
        if let fragment = components.percentEncodedFragment {
            components.percentEncodedFragment = sanitizedFragment(fragment)
        }
        let result = components.string ?? ""
        return isWithinUTF8Limit(result, limit: Self.maxOutputUTF8Bytes) ? result : ""
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
            return redactedRoute(fragment)
        }

        var query = URLComponents()
        query.percentEncodedQuery = String(encodedQuery)
        guard let queryItems = query.queryItems, !queryItems.isEmpty else {
            return nil
        }
        query.queryItems = redactingValues(in: queryItems)
        let separator = includesQuestionMark ? "?" : ""
        return "\(redactedRoute(String(prefix)))\(separator)\(query.percentEncodedQuery ?? "")"
    }

    private func redactedRoute(_ encodedRoute: String) -> String {
        encodedRoute.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "%3Credacted%3E" }
            .joined(separator: "/")
    }

    private func redactingValues(in items: [URLQueryItem]) -> [URLQueryItem] {
        items.map { item in
            URLQueryItem(
                name: item.value == nil ? "<redacted>" : item.name,
                value: item.value == nil ? nil : "<redacted>"
            )
        }
    }

    private func isWithinUTF8Limit(_ value: String, limit: Int) -> Bool {
        value.utf8.prefix(limit + 1).count <= limit
    }
}
