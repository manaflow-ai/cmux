/// One schema violation in a `cmux-app.json`, at a JSON Pointer path
/// (`/contributes/sidebarSections/0/render`). Codes follow the JSON Schema
/// keyword that failed (`required`, `pattern`, `additionalProperties`,
/// `propertyName`, `oneOf`, `type`, `const`, `enum`, `maxItems`,
/// `maxLength`, `minLength`, `uniqueItems`, `maxProperties`), matching the
/// shared fixtures in `cmux-tui/crates/cmux-app-host/schema/fixtures`.
public nonisolated struct AppManifestIssue: Sendable, Hashable, CustomStringConvertible {
    public var path: String
    public var code: String
    public var message: String

    public init(path: String, code: String, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }

    public var description: String { "\(path.isEmpty ? "/" : path): \(message) (\(code))" }
}

/// Why a manifest did not load: unreadable JSON, or schema issues (all of
/// them, in document order of discovery).
public nonisolated enum AppManifestError: Error, Sendable, Hashable, CustomStringConvertible {
    case unreadable(String)
    case invalid([AppManifestIssue])

    public var issues: [AppManifestIssue] {
        if case .invalid(let issues) = self { return issues }
        return []
    }

    public var description: String {
        switch self {
        case .unreadable(let reason): "cmux-app.json is not valid JSON: \(reason)"
        case .invalid(let issues): issues.map(\.description).joined(separator: "\n")
        }
    }
}
