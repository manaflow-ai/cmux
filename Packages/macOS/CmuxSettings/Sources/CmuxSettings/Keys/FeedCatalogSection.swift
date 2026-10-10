import Foundation

/// Settings for the right-sidebar Feed request bridge.
public struct FeedCatalogSection: SettingCatalogSection {
    /// Keeps Feed questions and permission requests pending until they are
    /// answered or the agent process is dismissed.
    public let blockingQuestions = DefaultsKey<Bool>(
        id: "feed.blockingQuestions",
        defaultValue: false,
        userDefaultsKey: "feedBlockingQuestions"
    )

    public init() {}
}
