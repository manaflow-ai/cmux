public import Foundation

/// The `notifications` block parsed from a `cmux.json` config scope: an optional
/// list of notification hooks plus how that list merges with broader scopes.
public struct CmuxNotificationConfigDefinition: Codable, Sendable, Hashable {
    /// The notification hooks declared at this config scope, if any.
    public var hooks: [CmuxNotificationHookDefinition]?
    /// How `hooks` combines with hooks inherited from broader config scopes.
    public var hooksMode: CmuxNotificationHooksMode?

    private enum CodingKeys: String, CodingKey {
        case hooks
        case hooksMode
    }

    /// Creates a notification config definition.
    public init(
        hooks: [CmuxNotificationHookDefinition]? = nil,
        hooksMode: CmuxNotificationHooksMode? = nil
    ) {
        self.hooks = hooks
        self.hooksMode = hooksMode
    }
}
