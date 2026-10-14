import Foundation
import PostHog

/// The PostHog SDK calls that set context on later events, injectable so
/// tests observe them without the SDK. Person identity (`identify`, `reset`)
/// is owned by the sign-in identity observer, not by product analytics.
struct PostHogContextCalls: Sendable {
    var register: @Sendable ([String: Any]) -> Void
    var group: @Sendable (String, String) -> Void

    static let live = PostHogContextCalls(
        register: { PostHogSDK.shared.register($0) },
        group: { PostHogSDK.shared.group(type: $0, key: $1, groupProperties: nil) }
    )
}
