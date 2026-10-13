import Foundation

/// Recognizes a live herdr client in a terminal surface so a relaunch can
/// reattach it. Not implemented yet: this placeholder detects nothing, so the
/// regression tests in HerdrResumeParserTests fail on behavior.
enum HerdrResumeParser {
    /// Set by herdr inside every pane it hosts.
    static let nestedEnvironmentKey = "HERDR_ENV"

    static func binding(
        arguments: [String],
        environment: [String: String],
        capturedAt: TimeInterval
    ) -> SurfaceResumeBindingSnapshot? {
        nil
    }

    static func isInsideHerdrPane(environment: [String: String]) -> Bool {
        false
    }
}
