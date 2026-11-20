/// The captured behavior of a `Button`, evaluated when the button is tapped
/// by a host runtime.
public struct ButtonAction: Codable, Sendable, Equatable {
    public let commands: [ActionCommand]

    /// Whether the user's own gesture fired this action.
    ///
    /// A host reads it before it puts UI in front of the user on the action's
    /// behalf, such as a close confirmation. The Swift dialect and the JSON
    /// DSL only run actions from a click, a menu item or a reorder drop, so it
    /// defaults to `true`. A JS sidebar can call `cmux(...)` at any time (on
    /// load, on a data update), so its runtime sets this from its
    /// user-activation scope: click, double-click and menu-item handlers.
    public let isUserGesture: Bool

    public init(commands: [ActionCommand], isUserGesture: Bool = true) {
        self.commands = commands
        self.isUserGesture = isUserGesture
    }

    private enum CodingKeys: String, CodingKey {
        case commands
        case isUserGesture
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commands = try container.decode([ActionCommand].self, forKey: .commands)
        isUserGesture = try container.decodeIfPresent(Bool.self, forKey: .isUserGesture) ?? true
    }
}
