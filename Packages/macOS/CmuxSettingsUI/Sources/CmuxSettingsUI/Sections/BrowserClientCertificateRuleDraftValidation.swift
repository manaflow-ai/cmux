import CmuxSettings
import Foundation

enum BrowserClientCertificateRuleDraftValidation {
    /// Returns whether every non-comment draft line is a complete rule.
    static func isValid(_ value: String) -> Bool {
        value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .allSatisfy { BrowserClientCertificateAutoSelectionRule($0) != nil }
    }
}
