import Foundation

/// Validated failure from the local PRDashboard socket boundary.
struct GHPRSocketError: Error, CustomStringConvertible, Sendable {
    let code: String
    let message: String
    let refreshKind: GHPRRefreshErrorKind

    var description: String { "\(code): \(message)" }

    init(code: String, message: String, refreshKind: GHPRRefreshErrorKind) {
        self.code = code
        self.message = Self.singleLine(message)
        self.refreshKind = refreshKind
    }

    private static func singleLine(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(normalized.prefix(240))
    }
}
