/// The visible parts of one delivered notification, as the Notification
/// Service extension reads and rewrites them.
public struct PushContent: Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String
    public var category: String
    public var level: PushInterruptionLevel
    public var sound: Bool

    public init(title: String, subtitle: String = "", body: String = "", category: String = "",
                level: PushInterruptionLevel = .active, sound: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
        self.level = level
        self.sound = sound
    }
}
