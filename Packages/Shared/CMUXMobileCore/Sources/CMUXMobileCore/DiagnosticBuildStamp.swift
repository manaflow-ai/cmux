import Foundation

/// Builds the short identity printed in every exported network report.
///
/// The git SHA and dev tag are signed bundle metadata, not runtime input. The
/// helper keeps iOS and macOS reports comparable and applies the same bounded
/// sanitization at their shared boundary.
extension DiagnosticReport {
    /// Returns a bounded `name version (build) tag sha` stamp from bundle data.
    public static func buildStamp(
        infoDictionary: [String: Any]?,
        fallbackName: String = "cmux"
    ) -> String {
        let info = infoDictionary ?? [:]
        let name = buildStampNonEmptyString(info["CFBundleName"]) ?? fallbackName
        let version = buildStampNonEmptyString(info["CFBundleShortVersionString"]) ?? "?"
        let build = buildStampNonEmptyString(info["CFBundleVersion"]) ?? "?"
        let tag = buildStampNonEmptyString(info["CMUXDevTag"])
        let sha = buildStampNonEmptyString(info["CMUXGitSHA"]).map {
            String($0.prefix(12))
        }

        var result = "\(name) \(version) (\(build))"
        if let tag {
            result += " tag \(tag)"
        }
        if let sha {
            result += " sha \(sha)"
        }
        return sanitizeBuildStamp(result)
    }

    private static func buildStampNonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
