public import Foundation

/// A validated `cmux://prompt` / `cmux://rules` deep link that pastes link-supplied
/// text into the current workspace terminal.
///
/// Parsing is pure and byte-faithful to the legacy implementation, including the
/// raw percent-encoded query handling (the text value is preserved exactly, not
/// re-normalized through `URLComponents.queryItems`). The active deep-link scheme
/// set is NOT resolved here; callers pass `supportedSchemes` explicitly so the
/// package stays free of the app's `AuthEnvironment`.
public struct CmuxTextURLRequest: Equatable {
    /// Whether the link carries a prompt or a rules payload.
    public enum Kind: String, Equatable {
        case prompt
        case rules
    }

    /// Maximum length of accepted link text.
    public static let maxTextLength = 8_000
    /// Maximum length of an accepted link name.
    public static let maxNameLength = 120
    /// Maximum length of an accepted link title.
    public static let maxTitleLength = 160
    /// Every deep-link scheme cmux ships across stable/nightly/dev builds.
    public static let supportedSchemes: Set<String> = CmuxSSHURLRequest.supportedSchemes

    public let originalURL: URL
    public let kind: Kind
    public let text: String
    public let name: String?
    public let title: String?
    public let noFocus: Bool

    /// The exact text to paste into the terminal.
    public var pasteText: String {
        text
    }

    private struct ParsedQueryItem {
        let name: String
        let value: String?
    }

    /// Parses `url` against the supplied active scheme set.
    public static func parse(
        _ url: URL,
        supportedSchemes: Set<String>
    ) -> Result<CmuxTextURLRequest?, CmuxTextURLParseError> {
        guard isSupportedScheme(url.scheme, supportedSchemes: supportedSchemes) else {
            return .success(nil)
        }
        guard let kind = textTarget(from: url) else {
            return .success(nil)
        }
        guard !containsPathPayload(url) else {
            return .failure(.unsupportedParameter("path"))
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.missingText)
        }

        let queryItems = parsedQueryItems(from: components)
        let allowedQueryNames: Set<String> = ["text", "name", "title", "no-focus"]
        var seenQueryNames = Set<String>()
        for item in queryItems {
            let name = item.name.lowercased()
            guard allowedQueryNames.contains(name) else {
                return .failure(.unsupportedParameter(displayParameterName(item.name)))
            }
            guard seenQueryNames.insert(name).inserted else {
                return .failure(.duplicateParameter(displayParameterName(item.name)))
            }
        }

        guard let text = exactQueryValue(namedAnyOf: ["text"], in: queryItems) else {
            return .failure(.missingText)
        }
        guard text.count <= maxTextLength else {
            return .failure(.textTooLong(maxLength: maxTextLength))
        }
        guard !containsUnsafeTextCharacter(text) else {
            return .failure(.textContainsUnsafeCharacters)
        }

        let name = normalizedQueryValue(namedAnyOf: ["name"], in: queryItems)
        if let name {
            guard name.count <= maxNameLength else {
                return .failure(.nameTooLong(maxLength: maxNameLength))
            }
            guard !containsUnsafeHiddenCharacter(name) else {
                return .failure(.nameContainsUnsafeCharacters)
            }
        }

        let title = normalizedQueryValue(namedAnyOf: ["title"], in: queryItems)
        if let title {
            guard title.count <= maxTitleLength else {
                return .failure(.titleTooLong(maxLength: maxTitleLength))
            }
            guard !containsUnsafeHiddenCharacter(title) else {
                return .failure(.titleContainsUnsafeCharacters)
            }
        }

        let noFocus: Bool
        switch normalizedBooleanValue(named: "no-focus", in: queryItems) {
        case .success(let value):
            noFocus = value
        case .failure(let error):
            return .failure(error)
        }

        return .success(CmuxTextURLRequest(
            originalURL: url,
            kind: kind,
            text: text,
            name: name,
            title: title,
            noFocus: noFocus
        ))
    }

    private static func isSupportedScheme(_ scheme: String?, supportedSchemes: Set<String>) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }

    private static func textTarget(from url: URL) -> Kind? {
        if let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(),
           !host.isEmpty {
            return kind(named: host)
        }

        let firstPathComponent = url.path
            .split(separator: "/")
            .first
            .map { String($0).lowercased() }
        guard let firstPathComponent else { return nil }
        return kind(named: firstPathComponent)
    }

    private static func kind(named value: String) -> Kind? {
        switch value {
        case "prompt":
            return .prompt
        case "rule", "rules":
            return .rules
        default:
            return nil
        }
    }

    private static func containsPathPayload(_ url: URL) -> Bool {
        if let host = url.host?.lowercased(),
           kind(named: host) != nil {
            return !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        }
        let pathComponents = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return pathComponents.first.map { kind(named: $0.lowercased()) != nil } == true && pathComponents.count > 1
    }

    private static func parsedQueryItems(from components: URLComponents) -> [ParsedQueryItem] {
        guard let query = components.percentEncodedQuery,
              !query.isEmpty else {
            return []
        }
        return query
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { rawPair in
                let parts = rawPair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = percentDecodedQueryComponent(String(parts[0])) ?? String(parts[0])
                let value = parts.count > 1
                    ? percentDecodedQueryComponent(String(parts[1])) ?? String(parts[1])
                    : nil
                return ParsedQueryItem(name: name, value: value)
            }
    }

    private static func percentDecodedQueryComponent(_ value: String) -> String? {
        value.removingPercentEncoding
    }

    private static func normalizedQueryValue(namedAnyOf names: Set<String>, in queryItems: [ParsedQueryItem]) -> String? {
        guard let value = queryItems.first(where: { names.contains($0.name.lowercased()) })?.value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func exactQueryValue(namedAnyOf names: Set<String>, in queryItems: [ParsedQueryItem]) -> String? {
        guard let value = queryItems.first(where: { names.contains($0.name.lowercased()) })?.value,
              !value.isEmpty else {
            return nil
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedBooleanValue(named name: String, in queryItems: [ParsedQueryItem]) -> Result<Bool, CmuxTextURLParseError> {
        guard let item = queryItems.first(where: { $0.name.lowercased() == name }) else {
            return .success(false)
        }
        guard let rawValue = item.value else {
            return .success(true)
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return .success(true)
        }
        switch normalized {
        case "1", "true", "yes", "on":
            return .success(true)
        case "0", "false", "no", "off":
            return .success(false)
        default:
            return .failure(.invalidBooleanParameter(displayParameterName(item.name)))
        }
    }

    private static func containsUnsafeTextCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    private static func containsUnsafeHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    private static func displayParameterName(_ name: String) -> String {
        if name.isEmpty || containsUnsafeHiddenCharacter(name) {
            return "?"
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "?"
        }
        let prefix = String(name.prefix(64))
        return prefix.count == name.count ? name : "\(prefix)..."
    }
}
