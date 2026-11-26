public import CmuxNextSettings
import Foundation

nonisolated extension AppsPageConfirmations {
    /// The card's source line for an app installed from a git reference: "From github.com/o/r/path
    /// at abc1234." (or "at v1.2.0 (abc1234)." when the listing names a `tag`), plus "Verified
    /// source." when the commit carries a signed tag (`verified_source: true`) and "Not reviewed by
    /// cmux." when the cmux registry has not approved the repository (`reviewed: false`). Nil when
    /// the listing names no `repository` and `commit` (an App Store app).
    public func sourceLine(_ detail: JSONValue?) -> String? {
        guard let repository = detail?["repository"]?.stringValue, !repository.isEmpty,
              let commit = detail?["commit"]?.stringValue, !commit.isEmpty else { return nil }
        var place = repository
        for prefix in ["https://", "http://"] where place.lowercased().hasPrefix(prefix) {
            place = String(place.dropFirst(prefix.count))
        }
        if let path = detail?["path"]?.stringValue, !path.isEmpty {
            place += path.hasPrefix("/") ? path : "/" + path
        }
        let short = String(commit.prefix(7))
        let version = detail?["tag"]?.stringValue.flatMap { $0.isEmpty ? nil : "\($0) (\(short))" } ?? short
        var line = String(format: PageStrings.appSource, place, version)
        if detail?["verified_source"]?.boolValue == true { line += " " + PageStrings.appVerifiedSource }
        if detail?["reviewed"]?.boolValue == false { line += " " + PageStrings.appNotReviewed }
        return line
    }
}
