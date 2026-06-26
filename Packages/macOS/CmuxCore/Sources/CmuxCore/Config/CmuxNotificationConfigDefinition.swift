/// The `notifications` section of a `cmux.json` configuration file.
///
/// Pure value type carrying the file's notification hook definitions and the
/// mode controlling how they merge with inherited hooks. Both fields are
/// optional so an omitted section decodes to all-`nil`.
public struct CmuxNotificationConfigDefinition: Codable, Sendable, Hashable {
    /// The notification hooks declared in this file, if any.
    public var hooks: [CmuxNotificationHookDefinition]?
    /// How these hooks combine with inherited hooks, if specified.
    public var hooksMode: CmuxNotificationHooksMode?

    /// Creates a notification configuration section.
    /// - Parameters:
    ///   - hooks: The notification hooks declared in this file.
    ///   - hooksMode: How these hooks combine with inherited hooks.
    public init(
        hooks: [CmuxNotificationHookDefinition]? = nil,
        hooksMode: CmuxNotificationHooksMode? = nil
    ) {
        self.hooks = hooks
        self.hooksMode = hooksMode
    }

    private enum CodingKeys: String, CodingKey {
        case hooks
        case hooksMode
    }
}
