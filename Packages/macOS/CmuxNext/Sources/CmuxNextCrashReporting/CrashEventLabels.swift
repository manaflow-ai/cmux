public import Sentry

/// The labels every cmux-next event carries, so its reports never group or
/// filter with the main app's in the shared Sentry project.
public nonisolated struct CrashEventLabels: Sendable, Equatable {
    /// The `app` tag value and the first fingerprint part.
    public static let app = "cmux-next"

    public let policy: CrashReportingPolicy

    public init(policy: CrashReportingPolicy) {
        self.policy = policy
    }

    /// Tags the event and puts `cmux-next` first in its fingerprint, so
    /// Sentry groups it into a cmux-next issue even when a stack looks like
    /// a main-app one. A fingerprint the event already has keeps its parts
    /// after the prefix.
    public func apply(to event: Event) {
        var tags = event.tags ?? [:]
        tags["app"] = Self.app
        tags["channel"] = policy.channel?.rawValue ?? "unknown"
        if let tag = policy.devTag { tags["dev_tag"] = tag }
        event.tags = tags
        let parts = event.fingerprint ?? ["{{ default }}"]
        if parts.first != Self.app { event.fingerprint = [Self.app] + parts }
    }
}
